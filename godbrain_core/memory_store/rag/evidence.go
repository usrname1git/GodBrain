package rag

import (
	"context"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type boundedSource struct {
	ID         primitive.ObjectID `bson:"_id"`
	SourceHash string             `bson:"source_hash"`
	Content    string             `bson:"content,omitempty"`
	ByteLength int                `bson:"byte_length"`
}

func (e *Engine) resolveCitations(
	ctx context.Context,
	generation string,
	document scoredDocument,
	sourceReadBudget int,
	contextBudget int,
) ([]Citation, string, int, int, error) {
	cursor, err := e.db.Collection(ProvenanceCollection).Find(
		ctx,
		bson.M{"generation": generation, "node_id": document.NodeID},
		options.Find().
			SetSort(bson.D{
				{Key: "source_hash", Value: 1},
				{Key: "external_source_id", Value: 1},
				{Key: "run_id", Value: 1},
			}).
			SetLimit(MaxCitationsPerResult),
	)
	if err != nil {
		return nil, "unavailable", 0, 0, err
	}
	defer cursor.Close(ctx)
	var provenance []Provenance
	if err = cursor.All(ctx, &provenance); err != nil {
		return nil, "unavailable", 0, 0, err
	}
	if len(provenance) == 0 {
		return []Citation{}, "missing_provenance", 0, 0, nil
	}

	citations := make([]Citation, 0, len(provenance))
	sourceBytes := 0
	excerptBytes := 0
	invalidCount := 0
	for _, entry := range provenance {
		if !validProvenanceShape(entry) {
			invalidCount++
			continue
		}
		maxRead := minInt(MaxSourceReadBytes, sourceReadBudget-sourceBytes)
		if maxRead <= 0 {
			invalidCount++
			continue
		}
		source, found, loadErr := e.loadBoundedSource(ctx, entry, maxRead)
		if loadErr != nil {
			return nil, "unavailable", sourceBytes, excerptBytes, loadErr
		}
		if !found || source.ByteLength < 0 || source.ByteLength > maxRead || source.Content == "" && source.ByteLength > 0 {
			invalidCount++
			continue
		}
		sourceBytes += source.ByteLength
		evidence, evidenceStatus, used := resolveEvidence(
			source.Content,
			entry.EvidenceSpans,
			contextBudget-excerptBytes,
		)
		excerptBytes += used
		citations = append(citations, Citation{
			RunID:            entry.RunID,
			SourceHash:       entry.SourceHash,
			ExternalSourceID: entry.ExternalSourceID,
			ExtractorID:      entry.ExtractorID,
			ExtractorVersion: entry.ExtractorVersion,
			SchemaVersion:    entry.SchemaVersion,
			CommittedAt:      entry.CommittedAt.UTC().Format("2006-01-02T15:04:05.000000000Z"),
			Evidence:         evidence,
			EvidenceStatus:   evidenceStatus,
		})
	}
	switch {
	case len(citations) == 0:
		return citations, "unavailable", sourceBytes, excerptBytes, nil
	case invalidCount > 0:
		return citations, "partial", sourceBytes, excerptBytes, nil
	default:
		return citations, "available", sourceBytes, excerptBytes, nil
	}
}

func validProvenanceShape(provenance Provenance) bool {
	return provenance.RunID != "" && len(provenance.RunID) <= 128 &&
		provenance.SourceHash != "" && len(provenance.SourceHash) <= 128 &&
		len(provenance.ExternalSourceID) <= 512 &&
		len(provenance.ExtractorID) <= 128 &&
		len(provenance.ExtractorVersion) <= 128 &&
		len(provenance.SchemaVersion) <= 128
}

func (e *Engine) loadBoundedSource(ctx context.Context, provenance Provenance, maxBytes int) (boundedSource, bool, error) {
	filter := bson.M{"source_hash": provenance.SourceHash}
	if !provenance.SourceID.IsZero() {
		filter["_id"] = provenance.SourceID
	}
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: filter}},
		{{Key: "$limit", Value: 1}},
		{{Key: "$project", Value: bson.M{
			"_id":         1,
			"source_hash": 1,
			"byte_length": bson.M{"$cond": bson.A{
				bson.M{"$eq": bson.A{bson.M{"$type": "$content"}, "string"}},
				bson.M{"$strLenBytes": "$content"},
				-1,
			}},
			"content": bson.M{"$cond": bson.A{
				bson.M{"$eq": bson.A{bson.M{"$type": "$content"}, "string"}},
				bson.M{"$cond": bson.A{
					bson.M{"$lte": bson.A{bson.M{"$strLenBytes": "$content"}, maxBytes}},
					"$content",
					"$$REMOVE",
				}},
				"$$REMOVE",
			}},
		}}},
	}
	cursor, err := e.db.Collection("sources").Aggregate(ctx, pipeline)
	if err != nil {
		return boundedSource{}, false, err
	}
	defer cursor.Close(ctx)
	var sources []boundedSource
	if err = cursor.All(ctx, &sources); err != nil {
		return boundedSource{}, false, err
	}
	if len(sources) == 0 {
		return boundedSource{}, false, nil
	}
	return sources[0], true, nil
}

func resolveEvidence(content string, spans []string, budget int) ([]EvidenceCitation, string, int) {
	if len(spans) == 0 {
		return nil, "not_provided", 0
	}
	type parsedSpan struct {
		raw        string
		start, end int
	}
	valid := make([]parsedSpan, 0, len(spans))
	invalid := 0
	if len(spans) > MaxEvidenceSpansInspect {
		invalid += len(spans) - MaxEvidenceSpansInspect
		spans = spans[:MaxEvidenceSpansInspect]
	}
	for _, span := range spans {
		start, end, ok := parseSpan(span)
		if !ok || !validUTF8Span(content, start, end) {
			invalid++
			continue
		}
		valid = append(valid, parsedSpan{raw: span, start: start, end: end})
	}
	sort.Slice(valid, func(i, j int) bool {
		if valid[i].start != valid[j].start {
			return valid[i].start < valid[j].start
		}
		if valid[i].end != valid[j].end {
			return valid[i].end < valid[j].end
		}
		return valid[i].raw < valid[j].raw
	})
	if len(valid) > MaxEvidencePerCitation {
		valid = valid[:MaxEvidencePerCitation]
	}
	result := make([]EvidenceCitation, 0, len(valid))
	used := 0
	for _, span := range valid {
		available := budget - used
		if available <= 0 {
			break
		}
		excerpt := truncateUTF8(content[span.start:span.end], minInt(MaxEvidenceExcerptBytes, available))
		used += len(excerpt)
		result = append(result, EvidenceCitation{
			Span:      span.raw,
			StartByte: span.start,
			EndByte:   span.end,
			Excerpt:   excerpt,
			ByteValid: true,
		})
	}
	switch {
	case len(result) == 0:
		return result, "invalid", used
	case invalid > 0:
		return result, "partial", used
	default:
		return result, "byte_valid", used
	}
}

func parseSpan(span string) (int, int, bool) {
	if len(span) < 5 || len(span) > 64 || span[0] != '[' || span[len(span)-1] != ']' {
		return 0, 0, false
	}
	startText, endText, found := strings.Cut(span[1:len(span)-1], ":")
	if !found {
		return 0, 0, false
	}
	start, startErr := strconv.Atoi(startText)
	end, endErr := strconv.Atoi(endText)
	if startErr != nil || endErr != nil || start < 0 || end <= start {
		return 0, 0, false
	}
	return start, end, true
}

func validUTF8Span(content string, start, end int) bool {
	if start < 0 || end > len(content) || end <= start {
		return false
	}
	if start > 0 && !utf8.RuneStart(content[start]) {
		return false
	}
	if end < len(content) && !utf8.RuneStart(content[end]) {
		return false
	}
	return utf8.ValidString(content[start:end])
}

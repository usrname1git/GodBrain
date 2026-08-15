package rag

import (
	"errors"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
)

func TestNormalizeQueryBoundsAndSanitizesOperators(t *testing.T) {
	normalized, tokens, err := NormalizeQuery(`  Architecture {"$ne":null} -- 安全 architecture  `)
	if err != nil {
		t.Fatalf("NormalizeQuery failed: %v", err)
	}
	if normalized != "architecture ne null 安全" {
		t.Fatalf("unexpected normalized query %q", normalized)
	}
	if !reflect.DeepEqual(tokens, []string{"architecture", "ne", "null", "安全"}) {
		t.Fatalf("unexpected tokens %#v", tokens)
	}
	if strings.ContainsAny(normalized, `${}"`) {
		t.Fatalf("normalized query retained Mongo or text-search operators: %q", normalized)
	}

	if _, _, err = NormalizeQuery(strings.Repeat("x", MaxQueryBytes+1)); !errors.Is(err, ErrQueryTooLarge) {
		t.Fatalf("expected ErrQueryTooLarge, got %v", err)
	}
}

func TestDocumentFilterHidesRejectedByDefault(t *testing.T) {
	filter := documentFilter("gen-1", SearchRequest{})
	hidden, ok := filter["status"].(bson.M)
	if !ok || hidden["$ne"] != "rejected" {
		t.Fatalf("default filter must hide rejected, got %#v", filter["status"])
	}
	explicit := documentFilter("gen-1", SearchRequest{Status: "rejected"})
	if explicit["status"] != "rejected" {
		t.Fatalf("explicit rejected filter lost: %#v", explicit["status"])
	}
}

func TestNormalizeRequestRejectsUnsafeMetadataFilters(t *testing.T) {
	_, _, _, err := normalizeRequest(SearchRequest{
		Query:        "safe",
		Kind:         bsonOperatorText(),
		TopK:         1,
		ContextBytes: 256,
	})
	if !errors.Is(err, ErrInvalidFilter) {
		t.Fatalf("expected ErrInvalidFilter, got %v", err)
	}
}

func bsonOperatorText() string {
	return `{"$gt":""}`
}

func TestRankAndDiversifyDeduplicatesAndUsesStableTies(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	candidates := []scoredDocument{
		{
			Document: Document{
				NodeID:        primitive.NewObjectID(),
				StableID:      "same",
				NodeVersion:   "v1",
				Status:        "candidate",
				Confidence:    0.4,
				Sector:        "architecture",
				SchemaVersion: "s1",
				NodeCreatedAt: now,
			},
			TextScore:         2,
			PrimarySourceHash: "source-a",
		},
		{
			Document: Document{
				NodeID:        primitive.NewObjectID(),
				StableID:      "same",
				NodeVersion:   "v2",
				Status:        "verified",
				Confidence:    0.9,
				Sector:        "architecture",
				SchemaVersion: "s2",
				NodeCreatedAt: now,
			},
			TextScore:         2,
			PrimarySourceHash: "source-a",
		},
		{
			Document: Document{
				NodeID:        primitive.NewObjectID(),
				StableID:      "other",
				NodeVersion:   "v1",
				Status:        "candidate",
				Confidence:    0.8,
				Sector:        "security",
				SchemaVersion: "s2",
				NodeCreatedAt: now,
			},
			TextScore:         2,
			PrimarySourceHash: "source-b",
		},
	}
	for index := range candidates {
		candidates[index].Scores = scoreDocument(candidates[index], "s2")
	}
	first := rankAndDiversify(candidates, 3)
	second := rankAndDiversify(candidates, 3)
	if len(first) != 2 {
		t.Fatalf("expected semantic dedupe to return two results, got %d", len(first))
	}
	if first[0].StableID != "same" || first[0].NodeVersion != "v2" {
		t.Fatalf("expected verified current-schema version first, got %#v", first[0])
	}
	if first[1].PrimarySourceHash != "source-b" {
		t.Fatalf("expected evidence-source diversity, got %#v", first[1])
	}
	if first[0].NodeID != second[0].NodeID || first[1].NodeID != second[1].NodeID {
		t.Fatal("ranking output was not deterministic")
	}
}

func TestScoreDocumentPreservesTrustLabels(t *testing.T) {
	verified := scoredDocument{Document: Document{Status: "verified", Confidence: 0.5}}
	rejected := scoredDocument{Document: Document{Status: "rejected", Confidence: 0.5}}
	verified.TextScore = 1
	rejected.TextScore = 1
	verifiedScore := scoreDocument(verified, "")
	rejectedScore := scoreDocument(rejected, "")
	if verifiedScore.Trust <= rejectedScore.Trust {
		t.Fatal("verified status should receive a larger trust component")
	}
	if math.IsNaN(rejectedScore.Total) {
		t.Fatal("rejected records must remain rankable with an explicit trust label")
	}
}

func TestValidDocumentShapeBoundsResponseIdentifiers(t *testing.T) {
	document := Document{
		NodeID:            primitive.NewObjectID(),
		Generation:        "generation-a",
		StableID:          "stable",
		NodeVersion:       "v1",
		Kind:              "claim",
		Sector:            "security",
		Status:            "candidate",
		SchemaVersion:     "s1",
		ProjectionVersion: ProjectionVersion,
		ProjectionSchema:  ProjectionSchema,
		IndexerVersion:    IndexerVersion,
	}
	if !validDocumentShape(document) {
		t.Fatal("expected normal document identifiers to be accepted")
	}
	document.StableID = strings.Repeat("x", 257)
	if validDocumentShape(document) {
		t.Fatal("oversized stable identity must not enter a bounded response")
	}
}

func TestLexicalSnippetRespectsUTF8Budget(t *testing.T) {
	content := "alpha 世界 beta gamma"
	snippet := lexicalSnippet(content, []string{"世界"}, 10)
	if len(snippet) > 10 {
		t.Fatalf("snippet exceeded budget: %d", len(snippet))
	}
	if !strings.Contains(snippet, "世界") {
		t.Fatalf("snippet did not center the matching Unicode token: %q", snippet)
	}
}

func TestReciprocalRankFusionAndCosineAreFiniteAndDeterministic(t *testing.T) {
	lexical := []scoredDocument{
		{Document: Document{NodeID: primitive.NewObjectID(), StableID: "a", NodeVersion: "v1"}, LexicalRank: 1},
		{Document: Document{NodeID: primitive.NewObjectID(), StableID: "b", NodeVersion: "v1"}, LexicalRank: 2},
	}
	semantic := []scoredDocument{
		{Document: lexical[1].Document, SemanticRank: 1, VectorSimilarity: 0.9},
		{Document: lexical[0].Document, SemanticRank: 2, VectorSimilarity: 0.8},
	}
	first := fuseCandidates(lexical, semantic)
	second := fuseCandidates(lexical, semantic)
	if len(first) != 2 || len(second) != 2 ||
		first[0].NodeID != second[0].NodeID ||
		first[1].NodeID != second[1].NodeID {
		t.Fatal("RRF fusion was not deterministic")
	}
	if reciprocalRank(0) != 0 || reciprocalRank(1) <= reciprocalRank(2) {
		t.Fatal("RRF rank contribution is invalid")
	}
	similarity, valid := cosineSimilarity([]float32{1, 0}, []float32{1, 0})
	if !valid || similarity != 1 || math.IsNaN(similarity) || math.IsInf(similarity, 0) {
		t.Fatalf("cosine similarity is invalid: %f valid=%v", similarity, valid)
	}
}

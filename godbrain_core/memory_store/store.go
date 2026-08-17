package memorystore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

var (
	ErrSkillOriginNotVerified    = errors.New("skill origin node is not verified")
	ErrSkillOriginHashMismatch   = errors.New("skill origin node hash mismatch")
	ErrKnowledgeNodeNotFound     = errors.New("knowledge node not found")
	ErrJudgmentIDRequired        = errors.New("judgment id is required")
	ErrJudgmentReasoningRequired = errors.New("judgment reasoning is required")
	ErrInvalidJudgmentStatus     = errors.New("judgment status must be verified, rejected, or stale")
	ErrInvalidStalePin           = errors.New("stale_pins requires windows-sre sector and a pin")
	ErrInvalidStatusTransition   = errors.New("status transition is not allowed")
)

var forbiddenDocumentPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)otpauth(?:-migration)?://`),
	regexp.MustCompile(`-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)\bbearer[ \t]+[A-Za-z0-9._~+/=-]{16,}`),
	regexp.MustCompile(`\b(?:AKIA|ASIA)[A-Z0-9]{16}\b`),
	regexp.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{40,255})\b`),
	regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}\b`),
	regexp.MustCompile(`\bxox[baprs]-[A-Za-z0-9-]{20,}\b`),
	regexp.MustCompile(`\b(?:sk_live_|rk_live_)[0-9A-Za-z]{16,}\b`),
	regexp.MustCompile(`\beyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\b`),
	regexp.MustCompile(`(?im)^[\s\v\x{001c}-\x{001f}\x{0085}\p{Z}]*(?:api[_-]?key|password|passwd|private[_-]?key|client[_-]?secret|access[_-]?token|bearer[_-]?token)[\s\v\x{001c}-\x{001f}\x{0085}\p{Z}]*[:=][\s\v\x{001c}-\x{001f}\x{0085}\p{Z}]*["']?[^\s\v\x{001c}-\x{001f}\x{0085}\p{Z}"']{8,}`),
}

var (
	safeSourceLabelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	safeExtractorIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
)

type Store struct {
	db *mongo.Database
}

func NewStore(db *mongo.Database) *Store {
	return &Store{db: db}
}

func normalizeClaim(claim Claim) Claim {
	claim.Type = strings.ToLower(strings.Join(strings.Fields(claim.Type), " "))
	claim.Content = strings.Join(strings.Fields(claim.Content), " ")
	return claim
}

func claimStableID(claim Claim) string {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte("claim\x00" + claim.Type + "\x00" + claim.Content))
	return hex.EncodeToString(hash.Sum(nil))
}

func parseEvidenceSpan(span string) (int, int, bool) {
	if len(span) < 5 || span[0] != '[' || span[len(span)-1] != ']' {
		return 0, 0, false
	}
	startText, endText, found := strings.Cut(span[1:len(span)-1], ":")
	if !found {
		return 0, 0, false
	}
	start, startErr := strconv.Atoi(startText)
	end, endErr := strconv.Atoi(endText)
	if startErr != nil || endErr != nil || start < 0 || end < start {
		return 0, 0, false
	}
	return start, end, true
}

func mergeClaims(existing, incoming Claim) Claim {
	if incoming.Confidence > existing.Confidence {
		existing.Confidence = incoming.Confidence
	}

	seen := make(map[string]struct{}, len(existing.EvidenceSpans)+len(incoming.EvidenceSpans))
	merged := make([]string, 0, len(existing.EvidenceSpans)+len(incoming.EvidenceSpans))
	for _, span := range existing.EvidenceSpans {
		if _, ok := seen[span]; ok {
			continue
		}
		seen[span] = struct{}{}
		merged = append(merged, span)
	}
	for _, span := range incoming.EvidenceSpans {
		if _, ok := seen[span]; ok {
			continue
		}
		seen[span] = struct{}{}
		merged = append(merged, span)
	}
	sort.Slice(merged, func(i, j int) bool {
		leftStart, leftEnd, leftValid := parseEvidenceSpan(merged[i])
		rightStart, rightEnd, rightValid := parseEvidenceSpan(merged[j])
		if leftValid != rightValid {
			return leftValid
		}
		if leftValid {
			if leftStart != rightStart {
				return leftStart < rightStart
			}
			if leftEnd != rightEnd {
				return leftEnd < rightEnd
			}
		}
		return merged[i] < merged[j]
	})
	existing.EvidenceSpans = merged
	return existing
}

// StartIngestion ensures idempotency for a run. Uses $setOnInsert to prevent duplicates.
// If retryOf is provided, it marks this run as a retry of a previous failed run.
func (s *Store) StartIngestion(ctx context.Context, sourceHash, extSourceID, extID, extVer, schemaVer string, retryOf *string) (*IngestionRun, bool, error) {
	return s.StartIngestionWithMetadata(ctx, sourceHash, extSourceID, extID, extVer, schemaVer, retryOf, nil)
}

// StartIngestionWithMetadata records optional adapter provenance on the run and
// immutable source observation without changing the ingestion identity.
func (s *Store) StartIngestionWithMetadata(ctx context.Context, sourceHash, extSourceID, extID, extVer, schemaVer string, retryOf *string, document *DocumentMetadata) (*IngestionRun, bool, error) {
	if document != nil {
		if err := validateDocumentMetadata(document, extSourceID); err != nil {
			return nil, false, err
		}
	}
	coll := s.db.Collection("ingestion_runs")

	// We only look for active/committed runs to enforce idempotency.
	// Failed runs are ignored by this filter, so a new one will be upserted.
	// If an active run is found but its lease has expired (stale for > 5 min),
	// we will consider it failed.
	fiveMinsAgo := time.Now().UTC().Add(-5 * time.Minute)

	// Pre-emptively fail stale active runs
	if _, err := coll.UpdateMany(ctx,
		bson.M{
			"source_hash": sourceHash,
			"active":      true,
			"status":      bson.M{"$in": []string{StatusStaging, StatusValidated}},
			"updated_at":  bson.M{"$lt": fiveMinsAgo},
		},
		bson.M{
			"$set": bson.M{
				"status":      StatusFailed,
				"active":      false,
				"error_msg":   "lease_timeout",
				"lease_token": "", // Revoke lease
				"updated_at":  time.Now().UTC(),
			},
		},
	); err != nil {
		return nil, false, errors.New("failed to expire stale ingestion leases: " + err.Error())
	}

	// Auto-detect retryOf if not provided
	if retryOf == nil {
		var lastFailed IngestionRun
		failedFilter := bson.M{
			"source_hash":       sourceHash,
			"extractor_id":      extID,
			"extractor_version": extVer,
			"schema_version":    schemaVer,
			"status":            StatusFailed,
		}
		opts := options.FindOne().SetSort(bson.D{{Key: "created_at", Value: -1}})
		if err := coll.FindOne(ctx, failedFilter, opts).Decode(&lastFailed); err == nil {
			retryOf = &lastFailed.RunID
		}
	} else {
		// Validate that the explicitly provided retryOf run is failed and matches the source_hash and schema versions
		var providedFailed IngestionRun
		err := coll.FindOne(ctx, bson.M{"run_id": *retryOf}).Decode(&providedFailed)
		if err != nil {
			return nil, false, errors.New("provided retryOf run not found: " + err.Error())
		}
		if providedFailed.Status != StatusFailed {
			return nil, false, errors.New("provided retryOf run is not in failed status")
		}
		if providedFailed.SourceHash != sourceHash {
			return nil, false, errors.New("provided retryOf run does not match source_hash")
		}
		if providedFailed.ExtractorID != extID || providedFailed.ExtractorVer != extVer || providedFailed.SchemaVersion != schemaVer {
			return nil, false, errors.New("provided retryOf run does not match extractor or schema versions")
		}
	}

	// We only look for active/committed runs to enforce idempotency.
	newRunID := uuid.New().String()
	now := time.Now().UTC()

	filter := bson.M{
		"source_hash":       sourceHash,
		"extractor_id":      extID,
		"extractor_version": extVer,
		"schema_version":    schemaVer,
		"active":            true,
		"status":            bson.M{"$ne": StatusFailed},
	}

	leaseToken := uuid.New().String()

	setOnInsert := bson.M{
		"run_id":             newRunID,
		"status":             StatusStaging,
		"active":             true,
		"lease_token":        leaseToken,
		"source_hash":        sourceHash,
		"extractor_id":       extID,
		"extractor_version":  extVer,
		"schema_version":     schemaVer,
		"external_source_id": extSourceID,
		"created_at":         now,
		"updated_at":         now,
	}

	if retryOf != nil {
		setOnInsert["retry_of"] = *retryOf
	}
	if document != nil {
		setOnInsert["document"] = document
	}

	update := bson.M{
		"$setOnInsert": setOnInsert,
	}

	opts := options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.After)

	var run IngestionRun
	err := coll.FindOneAndUpdate(ctx, filter, update, opts).Decode(&run)
	if mongo.IsDuplicateKeyError(err) {
		err = coll.FindOne(ctx, filter).Decode(&run)
	}
	if err != nil {
		return nil, false, err
	}

	// If the runID matches the one we just generated, it was created new.
	createdNew := run.RunID == newRunID

	// Record the observation of this source from this external session
	// We do this AFTER getting the runID so we have the definitive runID
	observation := bson.M{
		"source_hash":        sourceHash,
		"external_source_id": extSourceID,
		"extractor_id":       extID,
		"extractor_version":  extVer,
		"schema_version":     schemaVer,
		"run_id":             run.RunID,
		"created_at":         now,
	}
	if document != nil {
		observation["document"] = document
	}
	observationFilter := bson.M{
		"source_hash":        sourceHash,
		"external_source_id": extSourceID,
		"extractor_id":       extID,
		"extractor_version":  extVer,
		"schema_version":     schemaVer,
	}
	if document != nil {
		observationFilter["document.file_sha256"] = document.FileSHA256
	}
	_, err = s.db.Collection("source_observations").UpdateOne(ctx,
		observationFilter,
		bson.M{
			"$setOnInsert": observation,
		},
		options.Update().SetUpsert(true),
	)
	if mongo.IsDuplicateKeyError(err) {
		err = s.db.Collection("source_observations").FindOne(ctx, observationFilter).Err()
	}
	if err != nil {
		if createdNew {
			if _, rollbackErr := coll.UpdateOne(ctx,
				bson.M{"_id": run.ID, "status": StatusStaging, "lease_token": leaseToken},
				bson.M{"$set": bson.M{
					"status":      StatusFailed,
					"active":      false,
					"error_msg":   "observation_failed",
					"lease_token": "",
					"updated_at":  time.Now().UTC(),
				}},
			); rollbackErr != nil {
				return nil, false, errors.New("failed to record source observation: " + err.Error() + "; failed to release ingestion lease: " + rollbackErr.Error())
			}
		}
		return nil, false, errors.New("failed to record source observation: " + err.Error())
	}

	if !createdNew {
		run.LeaseToken = ""
	}

	return &run, createdNew, nil
}

// StageDistillation performs bulk writes of the parsed payload into staging.
func (s *Store) StageDistillation(ctx context.Context, runID string, leaseToken string, payload DistillationPayload) error {
	// Verify run status is Staging and lease token matches
	var run IngestionRun
	err := s.db.Collection("ingestion_runs").FindOne(ctx, bson.M{"run_id": runID, "lease_token": leaseToken}).Decode(&run)
	if err != nil {
		return errors.New("failed to find ingestion run or lease expired: " + err.Error())
	}
	if run.Status != StatusStaging {
		return errors.New("run is not in staging status")
	}
	if run.SourceHash != payload.Payload.Provenance.SourceHash {
		return errors.New("run source_hash does not match payload provenance source_hash")
	}
	if run.ExternalSourceID != payload.Payload.Provenance.SourceID {
		return errors.New("run external_source_id does not match payload provenance source_id")
	}
	if run.ExtractorVer != payload.ExtractorVersion || run.SchemaVersion != payload.SchemaVersion {
		return errors.New("run extractor or schema version does not match payload")
	}
	extractorID := payload.ExtractorID
	if extractorID == "" {
		extractorID = DefaultExtractorID
	}
	if run.ExtractorID != extractorID {
		return errors.New("run extractor_id does not match payload")
	}

	// Verify SourceHash matches the RawTranscript using Keccak-256
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(payload.RawTranscript))
	computedHashStr := hex.EncodeToString(hash.Sum(nil))
	if computedHashStr != payload.Payload.Provenance.SourceHash {
		return errors.New("source_hash mismatch: transcript hash does not match provenance source_hash")
	}

	// Force trust_tier to "candidate" if it tries to bypass verification
	if payload.Payload.TrustTier != "candidate" {
		return errors.New("trust_tier must be 'candidate'")
	}
	if err := ValidatePreIngestionPayload(payload); err != nil {
		return err
	}
	// Store the source as immutable content. Per-run provenance belongs on the run
	// and append-only association records, never on the source or node.
	sourceColl := s.db.Collection("sources")
	_, err = sourceColl.UpdateOne(ctx,
		bson.M{"source_hash": payload.Payload.Provenance.SourceHash},
		bson.M{
			"$setOnInsert": bson.M{
				"source_hash": payload.Payload.Provenance.SourceHash,
				"source_type": payload.Payload.Provenance.SourceType,
				"language":    payload.Payload.Provenance.Language,
				"content":     payload.RawTranscript,
				"created_at":  time.Now().UTC(),
			},
		},
		options.Update().SetUpsert(true),
	)
	if err != nil {
		return err
	}

	var sourceNode Source
	if err = sourceColl.FindOne(ctx, bson.M{"source_hash": payload.Payload.Provenance.SourceHash}).Decode(&sourceNode); err != nil {
		return errors.New("failed to resolve immutable source: " + err.Error())
	}
	if err = s.stageSourceChunks(ctx, payload); err != nil {
		return err
	}

	runResult, err := s.db.Collection("ingestion_runs").UpdateOne(ctx,
		bson.M{"run_id": runID, "status": StatusStaging, "lease_token": leaseToken},
		bson.M{
			"$set": bson.M{
				"prompt_hash":        payload.Payload.Provenance.PromptHash,
				"model_id":           payload.Payload.Provenance.ModelID,
				"model_hash":         payload.Payload.Provenance.ModelHash,
				"llm_temperature":    payload.Payload.Provenance.LLMTemperature,
				"source_id":          sourceNode.ID,
				"external_source_id": payload.Payload.Provenance.SourceID,
				"updated_at":         time.Now().UTC(),
			},
		},
	)
	if err != nil {
		return err
	}

	if runResult.MatchedCount != 1 {
		return errors.New("ingestion lease expired before staging")
	}

	now := time.Now().UTC()
	candidateDocuments := make(map[string]bson.M)
	evidenceSpansByStableID := make(map[string][]string)
	claimsByStableID := make(map[string]Claim)

	for _, claim := range payload.Payload.Claims {
		claim = normalizeClaim(claim)
		stableID := claimStableID(claim)
		if existing, ok := claimsByStableID[stableID]; ok {
			claim = mergeClaims(existing, claim)
		}
		claimsByStableID[stableID] = claim
	}

	for stableID, claim := range claimsByStableID {
		candidateDocuments[stableID] = bson.M{
			"stable_id":      stableID,
			"version":        "v1",
			"kind":           "claim",
			"sector":         claim.Type,
			"content":        claim.Content,
			"schema_version": payload.SchemaVersion,
			"status":         payload.Payload.TrustTier,
			"confidence":     claim.Confidence,
			"evidence_spans": claim.EvidenceSpans,
			"created_at":     now,
		}
		evidenceSpansByStableID[stableID] = claim.EvidenceSpans
	}

	for _, concept := range payload.Payload.CoreConcepts {
		hashStr := "concept_" + concept
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(hashStr))
		stableID := hex.EncodeToString(hash.Sum(nil))
		candidateDocuments[stableID] = bson.M{
			"stable_id":      stableID,
			"version":        "v1",
			"kind":           "concept",
			"sector":         "general",
			"content":        concept,
			"schema_version": payload.SchemaVersion,
			"status":         payload.Payload.TrustTier,
			"confidence":     1.0,
			"created_at":     now,
		}
	}

	for _, opsec := range payload.Payload.OpsecCandidates {
		hashStr := "opsec_" + opsec
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(hashStr))
		stableID := hex.EncodeToString(hash.Sum(nil))
		candidateDocuments[stableID] = bson.M{
			"stable_id":      stableID,
			"version":        "v1",
			"kind":           "opsec_candidate",
			"sector":         "security",
			"content":        opsec,
			"schema_version": payload.SchemaVersion,
			"status":         payload.Payload.TrustTier,
			"confidence":     1.0,
			"created_at":     now,
		}
	}

	if len(candidateDocuments) == 0 {
		return nil
	}

	nodesColl := s.db.Collection("knowledge_nodes")
	nodeWrites := make([]mongo.WriteModel, 0, len(candidateDocuments))
	stableIDs := make([]string, 0, len(candidateDocuments))
	for stableID, document := range candidateDocuments {
		stableIDs = append(stableIDs, stableID)
		nodeWrites = append(nodeWrites, mongo.NewUpdateOneModel().
			SetFilter(bson.M{"stable_id": stableID, "version": "v1"}).
			SetUpdate(bson.M{"$setOnInsert": document}).
			SetUpsert(true))
	}
	if _, err = nodesColl.BulkWrite(ctx, nodeWrites, options.BulkWrite().SetOrdered(false)); err != nil {
		return err
	}

	cursor, err := nodesColl.Find(ctx, bson.M{
		"stable_id": bson.M{"$in": stableIDs},
		"version":   "v1",
	})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)

	var nodes []KnowledgeNode
	if err = cursor.All(ctx, &nodes); err != nil {
		return err
	}
	if len(nodes) != len(candidateDocuments) {
		return errors.New("failed to resolve all staged knowledge nodes")
	}

	linkWrites := make([]mongo.WriteModel, 0, len(nodes))
	for _, node := range nodes {
		linkWrites = append(linkWrites, mongo.NewUpdateOneModel().
			SetFilter(bson.M{"run_id": runID, "node_id": node.ID}).
			SetUpdate(bson.M{"$setOnInsert": bson.M{
				"run_id":         runID,
				"node_id":        node.ID,
				"stable_id":      node.StableID,
				"node_version":   node.Version,
				"evidence_spans": evidenceSpansByStableID[node.StableID],
				"attempt_token":  leaseToken,
				"created_at":     now,
			}}).
			SetUpsert(true))
	}
	linksColl := s.db.Collection("run_node_links")
	if _, err = linksColl.BulkWrite(ctx, linkWrites, options.BulkWrite().SetOrdered(false)); err != nil {
		return err
	}

	if err = s.db.Collection("ingestion_runs").FindOne(ctx, bson.M{
		"run_id": runID, "lease_token": leaseToken, "status": StatusStaging,
	}).Decode(&run); err != nil {
		if _, compensationErr := linksColl.DeleteMany(ctx, bson.M{
			"run_id": runID, "attempt_token": leaseToken,
		}); compensationErr != nil {
			return errors.New("lease expired during staging writes: " + err.Error() + "; link compensation failed: " + compensationErr.Error())
		}
		return errors.New("lease expired during staging writes; attempt links removed")
	}

	return nil
}

// ValidatePreIngestionPayload verifies identities and content before a run or
// source observation can be persisted. StageDistillation repeats these checks.
func ValidatePreIngestionPayload(payload DistillationPayload) error {
	extractorID := payload.ExtractorID
	if extractorID == "" {
		extractorID = DefaultExtractorID
	}
	if !safeExtractorIDPattern.MatchString(extractorID) || payload.ExtractorVersion == "" ||
		len(payload.ExtractorVersion) > 128 || payload.SchemaVersion == "" ||
		len(payload.SchemaVersion) > 64 {
		return errors.New("extractor identity is invalid")
	}
	if payload.Payload.TrustTier != "candidate" {
		return errors.New("trust_tier must be 'candidate'")
	}
	if payload.Payload.Provenance.SourceID == "" || len(payload.Payload.Provenance.SourceID) > 512 ||
		payload.Payload.Provenance.SourceType == "" || len(payload.Payload.Provenance.SourceType) > 64 ||
		payload.Payload.Provenance.Language == "" || len(payload.Payload.Provenance.Language) > 64 {
		return errors.New("source provenance identity is invalid")
	}
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write([]byte(payload.RawTranscript))
	if hex.EncodeToString(hash.Sum(nil)) != payload.Payload.Provenance.SourceHash {
		return errors.New("source_hash mismatch: transcript hash does not match provenance source_hash")
	}
	return ValidateDocumentPayload(payload)
}

// ValidateDocumentPayload checks the optional local-document fields.
func ValidateDocumentPayload(payload DistillationPayload) error {
	isLocalDocument := payload.ExtractorID == "Local-Document-Adapter" ||
		payload.Payload.Provenance.SourceType == "local_document" ||
		strings.HasPrefix(payload.Payload.Provenance.SourceID, "local-document:") ||
		payload.Document != nil || len(payload.Chunks) != 0
	if !isLocalDocument {
		return nil
	}
	if payload.Document == nil || len(payload.Chunks) == 0 {
		return errors.New("document metadata and chunks must be provided together")
	}
	document := payload.Document
	if !safeExtractorIDPattern.MatchString(payload.ExtractorID) ||
		payload.ExtractorVersion == "" || len(payload.ExtractorVersion) > 128 ||
		payload.SchemaVersion == "" || len(payload.SchemaVersion) > 64 {
		return errors.New("document extractor identity is invalid")
	}
	if err := validateDocumentMetadata(document, payload.Payload.Provenance.SourceID); err != nil {
		return err
	}
	if payload.Payload.Provenance.SourceType != "local_document" ||
		payload.Payload.Provenance.Language != strings.Join(document.Languages, ",") {
		return errors.New("document provenance does not match its safe source identity")
	}
	contentHash := sha256.Sum256([]byte(payload.RawTranscript))
	if hex.EncodeToString(contentHash[:]) != document.ContentSHA256 {
		return errors.New("document content_sha256 does not match raw_transcript")
	}
	if document.ChunkCount != len(payload.Chunks) || len(payload.Chunks) > 256 {
		return errors.New("document chunk_count does not match bounded chunks")
	}
	if containsForbiddenDocumentContent(payload.RawTranscript) {
		return errors.New("document contains forbidden sensitive content")
	}
	raw := []byte(payload.RawTranscript)
	previousEnd := 0
	for index, chunk := range payload.Chunks {
		if chunk.Index != index || chunk.Count != len(payload.Chunks) {
			return errors.New("document chunks must have contiguous indexes and a consistent count")
		}
		if chunk.StartByte < 0 || chunk.EndByte <= chunk.StartByte || chunk.EndByte > len(raw) ||
			chunk.EndByte-chunk.StartByte > 32*1024 {
			return errors.New("document chunk byte range is invalid")
		}
		if string(raw[chunk.StartByte:chunk.EndByte]) != chunk.Text {
			return errors.New("document chunk text does not match raw_transcript byte range")
		}
		if chunk.StartByte < previousEnd || strings.TrimSpace(string(raw[previousEnd:chunk.StartByte])) != "" {
			return errors.New("document chunks overlap or omit non-whitespace content")
		}
		if chunk.Confidence != nil && (*chunk.Confidence < 0 || *chunk.Confidence > 1) {
			return errors.New("document chunk confidence is out of bounds")
		}
		previousEnd = chunk.EndByte
	}
	if strings.TrimSpace(string(raw[previousEnd:])) != "" {
		return errors.New("document chunks omit trailing non-whitespace content")
	}
	return nil
}

func validateDocumentMetadata(document *DocumentMetadata, sourceID string) error {
	if document.SourceLabel == "" || document.DisplayName == "" || document.ExtractionMethod == "" ||
		document.Backend == "" || document.BackendVersion == "" || len(document.Languages) == 0 {
		return errors.New("document provenance fields must not be blank")
	}
	if len(document.SourceLabel) > 64 || len(document.DisplayName) > 128 ||
		len(document.ExtractionMethod) > 64 || len(document.Backend) > 64 ||
		len(document.BackendVersion) > 64 || len(document.Languages) > 8 {
		return errors.New("document provenance exceeds field bounds")
	}
	if !safeSourceLabelPattern.MatchString(document.SourceLabel) ||
		!isSafeDisplayName(document.DisplayName) {
		return errors.New("document source label or display name is unsafe")
	}
	if !isLowerHexHash(document.FileSHA256, sha256.Size) || !isLowerHexHash(document.ContentSHA256, sha256.Size) {
		return errors.New("document SHA-256 fields must be lowercase hexadecimal")
	}
	if document.OCRConfidence != nil && (*document.OCRConfidence < 0 || *document.OCRConfidence > 1) {
		return errors.New("document OCR confidence is out of bounds")
	}
	expectedSourceID := "local-document:" + document.SourceLabel + ":" + document.DisplayName
	if sourceID != expectedSourceID {
		return errors.New("document metadata does not match its safe source identity")
	}
	if containsForbiddenDocumentContent(document.SourceLabel) ||
		containsForbiddenDocumentContent(document.DisplayName) {
		return errors.New("document contains forbidden sensitive content")
	}
	return nil
}

func isSafeDisplayName(value string) bool {
	if value == "" || len(value) > 128 || value == "." || value == ".." {
		return false
	}
	for _, character := range value {
		if character == '/' || character == '\\' || character == ':' ||
			character <= '\u001f' ||
			(character >= '\u007f' && character <= '\u009f') ||
			character == '\u2028' || character == '\u2029' {
			return false
		}
	}
	return true
}

func containsForbiddenDocumentContent(value string) bool {
	value = strings.Map(func(character rune) rune {
		switch character {
		case '\r', '\v', '\f', '\u001c', '\u001d', '\u001e', '\u0085', '\u2028', '\u2029':
			return '\n'
		default:
			return character
		}
	}, value)
	for _, pattern := range forbiddenDocumentPatterns {
		if pattern.MatchString(value) {
			return true
		}
	}
	return false
}

func isLowerHexHash(value string, byteLength int) bool {
	if len(value) != byteLength*2 || strings.ToLower(value) != value {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == byteLength
}

func (s *Store) stageSourceChunks(ctx context.Context, payload DistillationPayload) error {
	if len(payload.Chunks) == 0 {
		return nil
	}
	collection := s.db.Collection("chunks")
	writes := make([]mongo.WriteModel, 0, len(payload.Chunks))
	for _, chunk := range payload.Chunks {
		document := bson.M{
			"source_hash":       payload.Payload.Provenance.SourceHash,
			"extractor_id":      payload.ExtractorID,
			"extractor_version": payload.ExtractorVersion,
			"schema_version":    payload.SchemaVersion,
			"chunk_index":       chunk.Index,
			"start_byte":        chunk.StartByte,
			"end_byte":          chunk.EndByte,
			"text":              chunk.Text,
			"chunk_count":       chunk.Count,
			"confidence":        chunk.Confidence,
		}
		writes = append(writes, mongo.NewUpdateOneModel().
			SetFilter(sourceChunkFilter(payload, chunk.Index)).
			SetUpdate(bson.M{"$setOnInsert": document}).
			SetUpsert(true))
	}
	if _, err := collection.BulkWrite(ctx, writes, options.BulkWrite().SetOrdered(false)); err != nil {
		return errors.New("failed to stage source chunks: " + err.Error())
	}
	for _, expected := range payload.Chunks {
		var stored Chunk
		if err := collection.FindOne(ctx, sourceChunkFilter(payload, expected.Index)).Decode(&stored); err != nil {
			return errors.New("failed to resolve staged source chunk: " + err.Error())
		}
		if stored.StartByte != expected.StartByte || stored.EndByte != expected.EndByte ||
			stored.Text != expected.Text || stored.ChunkCount != expected.Count ||
			!equalOptionalFloat(stored.Confidence, expected.Confidence) {
			return errors.New("stored source chunk conflicts with immutable chunk content")
		}
	}

	return nil
}

func sourceChunkFilter(payload DistillationPayload, index int) bson.M {
	return bson.M{
		"source_hash":       payload.Payload.Provenance.SourceHash,
		"extractor_id":      payload.ExtractorID,
		"extractor_version": payload.ExtractorVersion,
		"schema_version":    payload.SchemaVersion,
		"chunk_index":       index,
	}
}

func equalOptionalFloat(left, right *float64) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

// CountRunNodeLinks returns the number of unique knowledge nodes linked to a run.
func (s *Store) CountRunNodeLinks(ctx context.Context, runID string) (int, error) {
	count, err := s.db.Collection("run_node_links").CountDocuments(ctx, bson.M{"run_id": runID})
	if err != nil {
		return 0, err
	}
	return int(count), nil
}

// RetrieveCommittedNodes returns immutable nodes linked to at least one committed run.
func (s *Store) RetrieveCommittedNodes(ctx context.Context, filter bson.M) ([]KnowledgeNode, error) {
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: filter}},
		{{Key: "$lookup", Value: bson.M{
			"from":         "run_node_links",
			"localField":   "_id",
			"foreignField": "node_id",
			"as":           "links",
		}}},
		{{Key: "$unwind", Value: "$links"}},
		{{Key: "$lookup", Value: bson.M{
			"from":         "ingestion_runs",
			"localField":   "links.run_id",
			"foreignField": "run_id",
			"as":           "runs",
		}}},
		{{Key: "$unwind", Value: "$runs"}},
		{{Key: "$match", Value: bson.M{"runs.status": StatusCommitted}}},
		{{Key: "$group", Value: bson.M{"_id": "$_id", "node": bson.M{"$first": "$$ROOT"}}}},
		{{Key: "$replaceRoot", Value: bson.M{"newRoot": "$node"}}},
		{{Key: "$unset", Value: bson.A{"links", "runs"}}},
	}
	nodeCursor, err := s.db.Collection("knowledge_nodes").Aggregate(ctx, pipeline)
	if err != nil {
		return nil, err
	}
	defer nodeCursor.Close(ctx)

	var nodes []KnowledgeNode
	if err = nodeCursor.All(ctx, &nodes); err != nil {
		return nil, err
	}

	return nodes, nil
}

func ValidateStatusJudgment(judgment StatusJudgment) error {
	if judgment.Command != JudgmentCommand {
		return errors.New("judgment command must be set_status")
	}
	id := strings.TrimSpace(judgment.ID)
	if id == "" || len(id) > 128 {
		return ErrJudgmentIDRequired
	}
	if judgment.Status != StatusVerified && judgment.Status != StatusRejected && judgment.Status != StatusStale {
		return ErrInvalidJudgmentStatus
	}
	reason := strings.Join(strings.Fields(judgment.Reasoning), " ")
	if len(reason) < MinJudgmentReason || len(judgment.Reasoning) > MaxJudgmentReason {
		return ErrJudgmentReasoningRequired
	}
	return nil
}

func AllowedStatusTransition(from, to string) bool {
	if from == to {
		return true
	}
	switch to {
	case StatusVerified:
		return from == StatusCandidate || from == StatusStale
	case StatusRejected:
		return from == StatusCandidate || from == StatusVerified || from == StatusStale
	case StatusStale:
		return from == StatusCandidate || from == StatusVerified
	case StatusCandidate:
		return from == StatusStale
	default:
		return false
	}
}

// SetNodeStatus changes only the judgment field on an immutable knowledge node.
func (s *Store) SetNodeStatus(ctx context.Context, id, status, reasoning string) (*KnowledgeNode, string, error) {
	judgment := StatusJudgment{Command: JudgmentCommand, ID: id, Status: status, Reasoning: reasoning}
	if err := ValidateStatusJudgment(judgment); err != nil {
		return nil, "", err
	}
	reasoning = strings.Join(strings.Fields(reasoning), " ")

	filter := bson.M{"stable_id": strings.TrimSpace(id)}
	if objectID, err := primitive.ObjectIDFromHex(strings.TrimSpace(id)); err == nil {
		filter = bson.M{"_id": objectID}
	}

	var node KnowledgeNode
	if err := s.db.Collection("knowledge_nodes").FindOne(ctx, filter).Decode(&node); err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return nil, "", ErrKnowledgeNodeNotFound
		}
		return nil, "", err
	}
	if !AllowedStatusTransition(node.Status, status) {
		return nil, "", ErrInvalidStatusTransition
	}

	from := node.Status
	if from != status {
		result, err := s.db.Collection("knowledge_nodes").UpdateOne(ctx,
			bson.M{"_id": node.ID, "status": from},
			bson.M{"$set": bson.M{"status": status}},
		)
		if err != nil {
			return nil, "", err
		}
		if result.MatchedCount != 1 {
			return nil, "", ErrInvalidStatusTransition
		}
		node.Status = status
	}

	if _, err := s.db.Collection("node_judgments").InsertOne(ctx, bson.M{
		"node_id":   node.ID,
		"stable_id": node.StableID,
		"from":      from,
		"to":        status,
		"reasoning": reasoning,
		"judged_at": time.Now().UTC(),
	}); err != nil {
		return nil, from, err
	}
	return &node, from, nil
}

func validOSPin(pin string) bool {
	if pin == "" || len(pin) > 80 {
		return false
	}
	for _, ch := range pin {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') || ch == '.' || ch == '/' ||
			ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}

// hasMismatchedOSPin is true when content carries os_pin= but not this live pin.
// Cards with no os_pin= (Learn-class) are not pin-scoped.
func hasMismatchedOSPin(content, pin string) bool {
	if !strings.Contains(content, "os_pin=") {
		return false
	}
	return !strings.Contains(content, "os_pin="+pin)
}

// StaleMismatchedPins marks verified windows-sre nodes whose content has os_pin=
// but not the live pin. Already-stale mismatches are returned too so a retry
// can resync the RAG projection without writing another judgment. Cards
// without os_pin= (Learn-class) stay verified.
func (s *Store) StaleMismatchedPins(ctx context.Context, sector, pin, reasoning string) ([]primitive.ObjectID, error) {
	sector = strings.TrimSpace(sector)
	pin = strings.TrimSpace(pin)
	reasoning = strings.Join(strings.Fields(reasoning), " ")
	if sector != "windows-sre" || !validOSPin(pin) || len(reasoning) < MinJudgmentReason {
		return nil, ErrInvalidStalePin
	}
	cursor, err := s.db.Collection("knowledge_nodes").Find(ctx, bson.M{
		"sector":  sector,
		"status":  bson.M{"$in": []string{StatusVerified, StatusStale}},
		"content": bson.M{"$regex": "os_pin="},
	}, options.Find().SetLimit(500))
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)

	var ids []primitive.ObjectID
	for cursor.Next(ctx) {
		var node KnowledgeNode
		if err := cursor.Decode(&node); err != nil {
			return ids, err
		}
		if !hasMismatchedOSPin(node.Content, pin) {
			continue
		}
		if node.Status == StatusVerified {
			if _, _, err := s.SetNodeStatus(ctx, node.ID.Hex(), StatusStale, reasoning); err != nil {
				return ids, err
			}
		}
		ids = append(ids, node.ID)
	}
	return ids, cursor.Err()
}

// Ensures that the origin node exists, is verified, and the hash matches exactly.
func (s *Store) PromoteSkill(ctx context.Context, name, content, originNodeID, originVer, originHash, schemaVer string) (*Skill, error) {
	nodesColl := s.db.Collection("knowledge_nodes")

	// 1. Fetch the origin node
	var node KnowledgeNode

	// Handle ObjectID vs string lookup gracefully
	filter := bson.M{"_id": originNodeID}
	if objID, parseErr := primitive.ObjectIDFromHex(originNodeID); parseErr == nil {
		filter = bson.M{"_id": objID}
	}

	err := nodesColl.FindOne(ctx, filter).Decode(&node)
	if err != nil {
		if err == mongo.ErrNoDocuments {
			return nil, ErrKnowledgeNodeNotFound
		}
		return nil, err
	}

	linkCursor, err := s.db.Collection("run_node_links").Find(ctx, bson.M{"node_id": node.ID})
	if err != nil {
		return nil, err
	}
	defer linkCursor.Close(ctx)

	var links []RunNodeLink
	if err = linkCursor.All(ctx, &links); err != nil {
		return nil, err
	}
	runIDs := make([]string, 0, len(links))
	for _, link := range links {
		runIDs = append(runIDs, link.RunID)
	}
	if len(runIDs) == 0 {
		return nil, errors.New("origin node is not linked to a committed ingestion run")
	}
	committedCount, err := s.db.Collection("ingestion_runs").CountDocuments(ctx, bson.M{
		"run_id": bson.M{"$in": runIDs},
		"status": StatusCommitted,
	})
	if err != nil {
		return nil, err
	}
	if committedCount == 0 {
		return nil, errors.New("origin node is not linked to a committed ingestion run")
	}

	// 2. Validate invariants (must be verified, version must match)
	if node.Status != "verified" {
		return nil, ErrSkillOriginNotVerified
	}

	if node.Version != originVer {
		return nil, errors.New("origin node version mismatch")
	}

	// Double check hash logic if implemented
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(node.Content))
	expectedHash := hex.EncodeToString(hash.Sum(nil))
	if expectedHash != originHash {
		return nil, ErrSkillOriginHashMismatch
	}

	// 3. Upsert Skill
	skillsColl := s.db.Collection("skills")
	now := time.Now().UTC()

	update := bson.M{
		"$set": bson.M{
			"version":        "v1", // Simplified
			"content":        content,
			"origin_node_id": originNodeID,
			"origin_version": originVer,
			"origin_hash":    originHash,
			"schema_version": schemaVer,
		},
		"$setOnInsert": bson.M{
			"name":       name,
			"created_at": now,
		},
	}

	opts := options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.After)

	var skill Skill
	err = skillsColl.FindOneAndUpdate(ctx, bson.M{"name": name}, update, opts).Decode(&skill)
	if mongo.IsDuplicateKeyError(err) {
		err = skillsColl.FindOne(ctx, bson.M{"name": name}).Decode(&skill)
	}
	if err != nil {
		return nil, err
	}

	return &skill, nil
}

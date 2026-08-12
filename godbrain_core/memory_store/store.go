package memorystore

import (
	"context"
	"encoding/hex"
	"errors"
	"sort"
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
	ErrSkillOriginNotVerified  = errors.New("skill origin node is not verified")
	ErrSkillOriginHashMismatch = errors.New("skill origin node hash mismatch")
	ErrKnowledgeNodeNotFound   = errors.New("knowledge node not found")
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

func mergeClaims(existing, incoming Claim) Claim {
	if incoming.Confidence > existing.Confidence {
		existing.Confidence = incoming.Confidence
	}

	seen := make(map[string]struct{}, len(existing.EvidenceSpans)+len(incoming.EvidenceSpans))
	merged := make([]string, 0, len(existing.EvidenceSpans)+len(incoming.EvidenceSpans))
	for _, span := range existing.EvidenceSpans {
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
	sort.Strings(merged)
	existing.EvidenceSpans = merged
	return existing
}

// StartIngestion ensures idempotency for a run. Uses $setOnInsert to prevent duplicates.
// If retryOf is provided, it marks this run as a retry of a previous failed run.
func (s *Store) StartIngestion(ctx context.Context, sourceHash, extSourceID, extID, extVer, schemaVer string, retryOf *string) (*IngestionRun, bool, error) {
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
	_, err = s.db.Collection("source_observations").UpdateOne(ctx,
		bson.M{
			"source_hash":        sourceHash,
			"external_source_id": extSourceID,
			"extractor_id":       extID,
			"extractor_version":  extVer,
			"schema_version":     schemaVer,
		},
		bson.M{
			"$setOnInsert": bson.M{
				"source_hash":        sourceHash,
				"external_source_id": extSourceID,
				"extractor_id":       extID,
				"extractor_version":  extVer,
				"schema_version":     schemaVer,
				"run_id":             run.RunID,
				"created_at":         now,
			},
		},
		options.Update().SetUpsert(true),
	)
	if mongo.IsDuplicateKeyError(err) {
		err = s.db.Collection("source_observations").FindOne(ctx, bson.M{
			"source_hash":        sourceHash,
			"external_source_id": extSourceID,
			"extractor_id":       extID,
			"extractor_version":  extVer,
			"schema_version":     schemaVer,
		}).Err()
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
				"run_id":        runID,
				"node_id":       node.ID,
				"stable_id":     node.StableID,
				"node_version":  node.Version,
				"attempt_token": leaseToken,
				"created_at":    now,
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
	nodesColl := s.db.Collection("knowledge_nodes")
	runsColl := s.db.Collection("ingestion_runs")

	cursor, err := runsColl.Find(ctx, bson.M{"status": StatusCommitted})
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)

	var committedRuns []IngestionRun
	if err = cursor.All(ctx, &committedRuns); err != nil {
		return nil, err
	}

	var committedRunIDs []string
	for _, r := range committedRuns {
		committedRunIDs = append(committedRunIDs, r.RunID)
	}

	if len(committedRunIDs) == 0 {
		return []KnowledgeNode{}, nil
	}

	linkCursor, err := s.db.Collection("run_node_links").Find(ctx, bson.M{
		"run_id": bson.M{"$in": committedRunIDs},
	})
	if err != nil {
		return nil, err
	}
	defer linkCursor.Close(ctx)

	var links []RunNodeLink
	if err = linkCursor.All(ctx, &links); err != nil {
		return nil, err
	}

	nodeIDSet := make(map[primitive.ObjectID]struct{}, len(links))
	for _, link := range links {
		nodeIDSet[link.NodeID] = struct{}{}
	}
	if len(nodeIDSet) == 0 {
		return []KnowledgeNode{}, nil
	}

	nodeIDs := make([]primitive.ObjectID, 0, len(nodeIDSet))
	for nodeID := range nodeIDSet {
		nodeIDs = append(nodeIDs, nodeID)
	}

	nodeFilter := make(bson.M, len(filter)+1)
	for key, value := range filter {
		nodeFilter[key] = value
	}
	nodeFilter["_id"] = bson.M{"$in": nodeIDs}

	nodeCursor, err := nodesColl.Find(ctx, nodeFilter)
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

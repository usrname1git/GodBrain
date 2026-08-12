package memorystore

import (
	"context"
	"encoding/hex"
	"errors"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/sha3"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var (
	ErrSkillOriginNotVerified  = errors.New("skill origin node is not verified")
	ErrSkillOriginHashMismatch = errors.New("skill origin node hash mismatch")
)

type Store struct {
	db *mongo.Database
}

func NewStore(db *mongo.Database) *Store {
	return &Store{db: db}
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
	_, _ = coll.UpdateMany(ctx, 
		bson.M{
			"source_hash": sourceHash,
			"active":      true,
			"status":      bson.M{"$in": []string{StatusStaging, StatusValidated}},
			"updated_at":  bson.M{"$lt": fiveMinsAgo},
		},
		bson.M{
			"$set": bson.M{
				"status": StatusFailed,
				"active": false,
				"error_msg": "lease_timeout",
				"lease_token": "", // Revoke lease
				"updated_at": time.Now().UTC(),
			},
		},
	)

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
		// Validate that the explicitly provided retryOf run is failed and matches the source_hash
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
	}

	// We only look for active/committed runs to enforce idempotency.
	newRunID := uuid.New().String()
	now := time.Now().UTC()

	// Record the observation of this source from this external session
	_, err := s.db.Collection("source_observations").UpdateOne(ctx,
		bson.M{
			"source_hash":        sourceHash,
			"external_source_id": extSourceID,
		},
		bson.M{
			"$setOnInsert": bson.M{
				"source_hash":        sourceHash,
				"external_source_id": extSourceID,
				"run_id":             newRunID, // Will be overridden to existing RunID if we didn't create a new one
				"created_at":         time.Now().UTC(),
			},
		},
		options.Update().SetUpsert(true),
	)
	if err != nil {
		return nil, false, errors.New("failed to record source observation: " + err.Error())
	}

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
		"run_id":            newRunID,
		"status":            StatusStaging,
		"active":            true,
		"lease_token":       leaseToken,
		"source_hash":       sourceHash,
		"extractor_id":      extID,
		"extractor_version": extVer,
		"schema_version":    schemaVer,
		"created_at":        now,
		"updated_at":        now,
	}
	
	if retryOf != nil {
		setOnInsert["retry_of"] = *retryOf
	}

	update := bson.M{
		"$setOnInsert": setOnInsert,
	}

	opts := options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.After)

	var run IngestionRun
	err = coll.FindOneAndUpdate(ctx, filter, update, opts).Decode(&run)
	if err != nil {
		return nil, false, err
	}

	// If the runID matches the one we just generated, it was created new.
	createdNew := run.RunID == newRunID

	// Start transaction for atomic migration
	session, err := s.db.Client().StartSession()
	if err != nil {
		return nil, false, errors.New("failed to start session for migration: " + err.Error())
	}
	defer session.EndSession(ctx)

	_, err = session.WithTransaction(ctx, func(sessCtx mongo.SessionContext) (interface{}, error) {
		// Update observation with actual returned RunID
		if !createdNew {
			_, innerErr := s.db.Collection("source_observations").UpdateOne(sessCtx,
				bson.M{"source_hash": sourceHash, "external_source_id": extSourceID},
				bson.M{"$set": bson.M{"run_id": run.RunID}},
			)
			if innerErr != nil {
				return nil, errors.New("failed to update source observation run_id: " + innerErr.Error())
			}
		}

		if createdNew && retryOf != nil {
			// Migrate candidate nodes from the failed run to this new run
			_, innerErr := s.db.Collection("knowledge_nodes").UpdateMany(sessCtx,
				bson.M{"ingestion_run_id": *retryOf, "status": "candidate"},
				bson.M{"$set": bson.M{"ingestion_run_id": newRunID}},
			)
			if innerErr != nil {
				// Rollback the newly created run by marking it failed, avoiding dangling references
				_, _ = coll.UpdateOne(sessCtx, bson.M{"_id": run.ID}, bson.M{"$set": bson.M{
					"status":      StatusFailed,
					"active":      false,
					"error_msg":   "migration_failed",
					"lease_token": "",
					"updated_at":  time.Now().UTC(),
				}})
				return nil, innerErr
			}
		}
		return nil, nil
	})

	if err != nil {
		return nil, false, err
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
	// 1. Stage Source
	sourceColl := s.db.Collection("sources")
	_, err = sourceColl.UpdateOne(ctx,
		bson.M{"source_hash": payload.Payload.Provenance.SourceHash},
		bson.M{
			"$setOnInsert": bson.M{
				"source_hash":        payload.Payload.Provenance.SourceHash,
				"external_source_id": payload.Payload.Provenance.SourceID,
				"source_type":        payload.Payload.Provenance.SourceType,
				"language":           payload.Payload.Provenance.Language,
				"content":            payload.RawTranscript,
				"created_at":         time.Now().UTC(),
			},
			"$set": bson.M{
				"ingestion_run_id": runID,
			},
		},
		options.Update().SetUpsert(true),
	)
	if err != nil {
		return err
	}

	// 2. Stage Nodes (Claims/Concepts/Opsec)
	// IMPORTANT: We only update nodes that are in "candidate" status.
	// If a node was previously promoted to "verified", a new staging run should NOT revert it to "candidate".
	var writeModels []mongo.WriteModel
	nodesColl := s.db.Collection("knowledge_nodes")
	now := time.Now().UTC()
	
	// Update IngestionRun with provenance details
	var sourceNode Source
	err = sourceColl.FindOne(ctx, bson.M{"source_hash": payload.Payload.Provenance.SourceHash}).Decode(&sourceNode)
	var sourceID primitive.ObjectID
	if err == nil {
		sourceID = sourceNode.ID
	}

	_, err = s.db.Collection("ingestion_runs").UpdateOne(ctx,
		bson.M{"run_id": runID},
		bson.M{
			"$set": bson.M{
				"prompt_hash":        payload.Payload.Provenance.PromptHash,
				"model_id":           payload.Payload.Provenance.ModelID,
				"model_hash":         payload.Payload.Provenance.ModelHash,
				"llm_temperature":    payload.Payload.Provenance.LLMTemperature,
				"source_id":          sourceID,
				"external_source_id": payload.Payload.Provenance.SourceID,
			},
		},
	)
	if err != nil {
		return err
	}

	// Claims
	for _, claim := range payload.Payload.Claims {
		hashStr := claim.ClaimID + "_" + claim.Type + "_" + claim.Content
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(hashStr))
		stableID := hex.EncodeToString(hash.Sum(nil))

		wm := mongo.NewUpdateOneModel().
			SetFilter(bson.M{"stable_id": stableID, "version": "v1"}).
			SetUpdate(bson.M{
				"$setOnInsert": bson.M{
					"stable_id":        stableID,
					"version":          "v1",
					"kind":             "claim",
					"sector":           claim.Type,
					"content":          claim.Content,
					"schema_version":   payload.SchemaVersion,
					"status":           payload.Payload.TrustTier, // typically "candidate"
					"confidence":       claim.Confidence,
					"evidence_spans":   claim.EvidenceSpans,
					"ingestion_run_id": runID,
					"created_at":       now,
				},
			}).
			SetUpsert(true)
		writeModels = append(writeModels, wm)
	}

	// Core Concepts
	for _, concept := range payload.Payload.CoreConcepts {
		hashStr := "concept_" + concept
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(hashStr))
		stableID := hex.EncodeToString(hash.Sum(nil))

		wm := mongo.NewUpdateOneModel().
			SetFilter(bson.M{"stable_id": stableID, "version": "v1"}).
			SetUpdate(bson.M{
				"$setOnInsert": bson.M{
					"stable_id":        stableID,
					"version":          "v1",
					"kind":             "concept",
					"sector":           "general",
					"content":          concept,
					"schema_version":   payload.SchemaVersion,
					"status":           payload.Payload.TrustTier,
					"confidence":       1.0,
					"ingestion_run_id": runID,
					"created_at":       now,
				},
			}).
			SetUpsert(true)
		writeModels = append(writeModels, wm)
	}

	// Opsec Candidates
	for _, opsec := range payload.Payload.OpsecCandidates {
		hashStr := "opsec_" + opsec
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(hashStr))
		stableID := hex.EncodeToString(hash.Sum(nil))

		wm := mongo.NewUpdateOneModel().
			SetFilter(bson.M{"stable_id": stableID, "version": "v1"}).
			SetUpdate(bson.M{
				"$setOnInsert": bson.M{
					"stable_id":        stableID,
					"version":          "v1",
					"kind":             "opsec_candidate",
					"sector":           "security",
					"content":          opsec,
					"schema_version":   payload.SchemaVersion,
					"status":           payload.Payload.TrustTier,
					"confidence":       1.0,
					"ingestion_run_id": runID,
					"created_at":       now,
				},
			}).
			SetUpsert(true)
		writeModels = append(writeModels, wm)
	}

	if len(writeModels) > 0 {
		_, err = nodesColl.BulkWrite(ctx, writeModels, options.BulkWrite().SetOrdered(false))
		if err != nil {
			return err
		}
	}

	// Double check lease token to ensure we didn't lose it during bulk write
	err = s.db.Collection("ingestion_runs").FindOne(ctx, bson.M{"run_id": runID, "lease_token": leaseToken, "status": StatusStaging}).Decode(&run)
	if err != nil {
		// Compensation: we lost the lease! Delete the candidate nodes we just wrote.
		_, _ = nodesColl.DeleteMany(ctx, bson.M{"ingestion_run_id": runID, "status": "candidate"})
		return errors.New("lease expired during staging writes, compensation applied")
	}

	return nil
}

// RetrieveCommittedNodes returns all knowledge nodes that belong to a committed ingestion run.
func (s *Store) RetrieveCommittedNodes(ctx context.Context, filter bson.M) ([]KnowledgeNode, error) {
	nodesColl := s.db.Collection("knowledge_nodes")
	runsColl := s.db.Collection("ingestion_runs")

	// 1. Get all committed run IDs
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

	// 2. Add run ID filter
	if filter == nil {
		filter = bson.M{}
	}
	filter["ingestion_run_id"] = bson.M{"$in": committedRunIDs}

	// 3. Find nodes
	nodeCursor, err := nodesColl.Find(ctx, filter)
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
			return nil, ErrRunNotFound
		}
		return nil, err
	}

	// 1b. Verify the node's run is committed
	var run IngestionRun
	err = s.db.Collection("ingestion_runs").FindOne(ctx, bson.M{"run_id": node.IngestionRunID}).Decode(&run)
	if err != nil || run.Status != StatusCommitted {
		return nil, errors.New("origin node belongs to an uncommitted ingestion run")
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
	if err != nil {
		return nil, err
	}

	return &skill, nil
}

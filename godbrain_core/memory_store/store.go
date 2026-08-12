package memorystore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/google/uuid"
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
func (s *Store) StartIngestion(ctx context.Context, sourceHash, extID, extVer, schemaVer string, retryOf *string) (*IngestionRun, bool, error) {
	coll := s.db.Collection("ingestion_runs")
	
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
	}

	// We only look for active/committed runs to enforce idempotency.
	// Failed runs are ignored by this filter, so a new one will be upserted.
	filter := bson.M{
		"source_hash":       sourceHash,
		"extractor_id":      extID,
		"extractor_version": extVer,
		"schema_version":    schemaVer,
		"active":            true,
		"status":            bson.M{"$ne": StatusFailed},
	}

	newRunID := uuid.New().String()
	now := time.Now().UTC()

	setOnInsert := bson.M{
		"run_id":            newRunID,
		"status":            StatusStaging,
		"active":            true,
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
	err := coll.FindOneAndUpdate(ctx, filter, update, opts).Decode(&run)
	if err != nil {
		return nil, false, err
	}

	// If the runID matches the one we just generated, it was created new.
	createdNew := run.RunID == newRunID
	
	if createdNew && retryOf != nil {
		// Migrate candidate nodes from the failed run to this new run
		s.db.Collection("knowledge_nodes").UpdateMany(ctx,
			bson.M{"ingestion_run_id": *retryOf, "status": "candidate"},
			bson.M{"$set": bson.M{"ingestion_run_id": newRunID}},
		)
	}
	
	return &run, createdNew, nil
}

// StageDistillation performs bulk writes of the parsed payload into staging.
func (s *Store) StageDistillation(ctx context.Context, runID string, payload DistillationPayload) error {
	// 1. Stage Source
	sourceColl := s.db.Collection("sources")
	_, err := sourceColl.UpdateOne(ctx,
		bson.M{"source_hash": payload.Payload.Provenance.SourceHash},
		bson.M{
			"$setOnInsert": bson.M{
				"source_hash":      payload.Payload.Provenance.SourceHash,
				"source_type":      payload.Payload.Provenance.SourceType,
				"language":         payload.Payload.Provenance.Language,
				"content":          payload.RawTranscript,
				"created_at":       time.Now().UTC(),
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
				"prompt_hash":     payload.Payload.Provenance.PromptHash,
				"model_id":        payload.Payload.Provenance.ModelID,
				"model_hash":      payload.Payload.Provenance.ModelHash,
				"llm_temperature": payload.Payload.Provenance.LLMTemperature,
				"source_id":       sourceID,
			},
		},
	)
	if err != nil {
		return err
	}

	// Claims
	for _, claim := range payload.Payload.Claims {
		hashStr := claim.ClaimID + "_" + claim.Type + "_" + claim.Content
		stableHash := sha256.Sum256([]byte(hashStr))
		stableID := hex.EncodeToString(stableHash[:])

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
		stableHash := sha256.Sum256([]byte(hashStr))
		stableID := hex.EncodeToString(stableHash[:])

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
		stableHash := sha256.Sum256([]byte(hashStr))
		stableID := hex.EncodeToString(stableHash[:])

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
	contentHash := sha256.Sum256([]byte(node.Content))
	expectedHash := hex.EncodeToString(contentHash[:])
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

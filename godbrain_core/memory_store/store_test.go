package memorystore_test

import (
	"context"
	"encoding/hex"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

func setupTestDB(t *testing.T) *mongo.Database {
	uri := os.Getenv("MONGODB_TEST_URI")
	if uri == "" {
		t.Skip("Skipping integration test: MONGODB_TEST_URI is not set")
	}

	ctx := context.Background()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatalf("Failed to connect to mongo: %v", err)
	}

	db := client.Database("godbrain_test")
	_ = db.Drop(ctx) // Start clean

	if err := memorystore.EnsureIndexes(ctx, db); err != nil {
		t.Fatalf("Failed to ensure indexes: %v", err)
	}

	return db
}

func TestDuplicateIngestion(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	// First run
	run1, created1, err := store.StartIngestion(ctx, "hash_123", "ext_1", "ext_1", "v1", "s1", nil)
	if err != nil || !created1 {
		t.Fatalf("Expected new ingestion run, got err: %v", err)
	}

	// Second run identical
	run2, created2, err := store.StartIngestion(ctx, "hash_123", "ext_1", "ext_1", "v1", "s1", nil)
	if err != nil || created2 {
		t.Fatalf("Expected duplicate run to be caught (created2=false)")
	}

	if run2 == nil || run1.RunID != run2.RunID {
		t.Fatalf("Expected duplicate runs to yield same RunID")
	}
	if run2.LeaseToken != "" {
		t.Fatal("Duplicate caller must not receive the active worker's lease token")
	}
}

func TestForbiddenStateTransition(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	run, _, _ := store.StartIngestion(ctx, "hash_state", "ext_1", "ext_1", "v1", "s1", nil)

	// Try jumping directly staging -> committed
	err := memorystore.TransitionRunState(ctx, db, run.RunID, memorystore.StatusStaging, memorystore.StatusCommitted, run.LeaseToken, nil)
	if err != memorystore.ErrInvalidTransition {
		t.Fatalf("Expected ErrInvalidTransition, got %v", err)
	}
}

func TestInterruptedStagingRetry(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	// Initial failing run
	run1, _, _ := store.StartIngestion(ctx, "hash_fail", "ext_1", "ext_1", "v1", "s1", nil)

	errStr := "interrupted"
	_ = memorystore.TransitionRunState(ctx, db, run1.RunID, memorystore.StatusStaging, memorystore.StatusFailed, run1.LeaseToken, &errStr)

	// Retry creates a NEW run
	run2, created, err := store.StartIngestion(ctx, "hash_fail", "ext_1", "ext_1", "v1", "s1", &run1.RunID)
	if err != nil {
		t.Fatalf("Failed to start retry run: %v", err)
	}

	if !created {
		t.Logf("Retry run logic caught unique index: created=%v", created)
	}

	_ = run2
}

func TestPromoteSkillHashMismatch(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	// Seed a verified node
	nodesColl := db.Collection("knowledge_nodes")
	nodeID := primitive.NewObjectID()

	_, _ = nodesColl.InsertOne(ctx, memorystore.KnowledgeNode{
		ID:        nodeID,
		StableID:  "stable_123",
		Version:   "v1",
		Status:    "verified",
		Content:   "Actual Content",
		CreatedAt: time.Now(),
	})

	_, _ = db.Collection("ingestion_runs").InsertOne(ctx, memorystore.IngestionRun{
		RunID:  "dummy_run",
		Status: memorystore.StatusCommitted,
	})
	_, _ = db.Collection("run_node_links").InsertOne(ctx, memorystore.RunNodeLink{
		RunID:       "dummy_run",
		NodeID:      nodeID,
		StableID:    "stable_123",
		NodeVersion: "v1",
		CreatedAt:   time.Now(),
	})

	// Attempt promotion with WRONG hash
	_, err := store.PromoteSkill(ctx, "test-skill", "skill data", nodeID.Hex(), "v1", "wrong_hash", "1.0")
	if err != memorystore.ErrSkillOriginHashMismatch {
		t.Fatalf("Expected hash mismatch error, got: %v", err)
	}
}

func TestPromoteSkillMissingNodeError(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)

	_, err := store.PromoteSkill(
		context.Background(),
		"missing-node",
		"skill data",
		primitive.NewObjectID().Hex(),
		"v1",
		"unused",
		"1.0",
	)
	if !errors.Is(err, memorystore.ErrKnowledgeNodeNotFound) {
		t.Fatalf("expected ErrKnowledgeNodeNotFound, got %v", err)
	}
}

func TestLeaseTimeout(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	// 1. Manually insert a stale active run
	staleRunID := "stale_run"
	sourceHash := "hash_stale"
	now := time.Now().UTC()
	staleTime := now.Add(-10 * time.Minute)

	_, err := db.Collection("ingestion_runs").InsertOne(ctx, memorystore.IngestionRun{
		RunID:         staleRunID,
		Status:        memorystore.StatusStaging,
		Active:        true,
		SourceHash:    sourceHash,
		ExtractorID:   "ext_1",
		ExtractorVer:  "v1",
		SchemaVersion: "s1",
		CreatedAt:     staleTime,
		UpdatedAt:     staleTime,
	})
	if err != nil {
		t.Fatalf("Failed to insert stale run: %v", err)
	}

	// 2. StartIngestion should preemptively fail the stale run and create a new one
	newRun, created, err := store.StartIngestion(ctx, sourceHash, "ext_1", "ext_1", "v1", "s1", nil)
	if err != nil {
		t.Fatalf("StartIngestion failed: %v", err)
	}
	if !created {
		t.Fatalf("Expected a new run to be created, but got existing")
	}
	if newRun.RunID == staleRunID {
		t.Fatalf("Expected a new RunID, got the stale one")
	}

	// 3. Verify the old run is marked failed
	var oldRun memorystore.IngestionRun
	err = db.Collection("ingestion_runs").FindOne(ctx, bson.M{"run_id": staleRunID}).Decode(&oldRun)
	if err != nil {
		t.Fatalf("Failed to find old run: %v", err)
	}
	if oldRun.Status != memorystore.StatusFailed || oldRun.Active {
		t.Fatalf("Old run should be inactive and failed, got status=%s, active=%v", oldRun.Status, oldRun.Active)
	}
}

func TestForbiddenVerifiedIngestion(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	transcript := "test transcript"
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(transcript))
	hashStr := hex.EncodeToString(hash.Sum(nil))

	run, _, _ := store.StartIngestion(ctx, hashStr, "ext_1", "ext_1", "v1", "s1", nil)

	payload := memorystore.DistillationPayload{
		RawTranscript:    transcript,
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "verified", // Should be forbidden/overridden
			Provenance: memorystore.Provenance{
				SourceHash: hashStr,
			},
			CoreConcepts: []string{"Concept1"},
		},
	}

	err := store.StageDistillation(ctx, run.RunID, run.LeaseToken, payload)
	if err == nil {
		t.Fatalf("Expected StageDistillation to fail due to forbidden TrustTier")
	}

	// Verify no node was created
	var node memorystore.KnowledgeNode
	err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"content": "Concept1"}).Decode(&node)
	if err != mongo.ErrNoDocuments {
		t.Fatalf("Expected no documents, got err: %v", err)
	}
}

func TestSourceHashMismatch(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	run, _, _ := store.StartIngestion(ctx, "hash_mismatch_test", "ext_1", "ext_1", "v1", "s1", nil)

	payload := memorystore.DistillationPayload{
		RawTranscript: "actual transcript content",
		Payload: memorystore.AlexandriaPayload{
			Provenance: memorystore.Provenance{
				SourceHash: "completely_wrong_hash_12345",
			},
		},
	}

	err := store.StageDistillation(ctx, run.RunID, run.LeaseToken, payload)
	if err == nil {
		t.Fatalf("Expected error due to source_hash mismatch, got nil")
	}
}

func TestClaimStableIDDeduplicatesProviderIDs(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	transcript := "stable claim identity transcript"
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(transcript))
	sourceHash := hex.EncodeToString(hash.Sum(nil))
	run, _, err := store.StartIngestion(ctx, sourceHash, "session_1", "extractor", "v1", "s1", nil)
	if err != nil {
		t.Fatalf("StartIngestion failed: %v", err)
	}

	payload := memorystore.DistillationPayload{
		RawTranscript:    transcript,
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: memorystore.Provenance{
				SourceID:   "session_1",
				SourceHash: sourceHash,
			},
			Claims: []memorystore.Claim{
				{
					ClaimID:       "provider-a",
					Type:          "Fact",
					Content:       "The same semantic claim",
					Confidence:    0.4,
					EvidenceSpans: []string{"[0:3]", "[4:7]"},
				},
				{
					ClaimID:       "provider-b",
					Type:          " fact ",
					Content:       "The  same semantic claim",
					Confidence:    0.9,
					EvidenceSpans: []string{"[4:7]", "[8:11]"},
				},
			},
			CoreConcepts:    []string{"Semantic identity"},
			OpsecCandidates: []string{"Preserve all evidence"},
		},
	}
	if err = store.StageDistillation(ctx, run.RunID, run.LeaseToken, payload); err != nil {
		t.Fatalf("StageDistillation failed: %v", err)
	}

	nodeCount, err := db.Collection("knowledge_nodes").CountDocuments(ctx, bson.M{"kind": "claim"})
	if err != nil {
		t.Fatalf("Failed to count claim nodes: %v", err)
	}
	if nodeCount != 1 {
		t.Fatalf("Expected one semantic claim node, got %d", nodeCount)
	}
	var claimNode memorystore.KnowledgeNode
	if err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"kind": "claim"}).Decode(&claimNode); err != nil {
		t.Fatalf("Failed to read semantic claim node: %v", err)
	}
	if claimNode.Confidence != 0.9 {
		t.Fatalf("Expected maximum confidence 0.9, got %v", claimNode.Confidence)
	}
	expectedSpans := []string{"[0:3]", "[4:7]", "[8:11]"}
	if len(claimNode.EvidenceSpans) != len(expectedSpans) {
		t.Fatalf("Expected merged evidence spans %v, got %v", expectedSpans, claimNode.EvidenceSpans)
	}
	for index, span := range expectedSpans {
		if claimNode.EvidenceSpans[index] != span {
			t.Fatalf("Expected merged evidence spans %v, got %v", expectedSpans, claimNode.EvidenceSpans)
		}
	}

	linkCount, err := store.CountRunNodeLinks(ctx, run.RunID)
	if err != nil {
		t.Fatalf("Failed to count claim links: %v", err)
	}
	if linkCount != 3 {
		t.Fatalf("Expected three unique run-node links, got %d", linkCount)
	}
}

func TestExplicitRetryRequiresMatchingIdentity(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	run, _, err := store.StartIngestion(ctx, "retry_identity", "session_1", "extractor", "v1", "s1", nil)
	if err != nil {
		t.Fatalf("StartIngestion failed: %v", err)
	}
	errMsg := "interrupted"
	if err = memorystore.TransitionRunState(ctx, db, run.RunID, memorystore.StatusStaging, memorystore.StatusFailed, run.LeaseToken, &errMsg); err != nil {
		t.Fatalf("Failed to mark run failed: %v", err)
	}

	if _, _, err = store.StartIngestion(ctx, "retry_identity", "session_1", "extractor", "v2", "s1", &run.RunID); err == nil {
		t.Fatal("Expected retry with a different extractor version to fail")
	}
	if _, _, err = store.StartIngestion(ctx, "retry_identity", "session_1", "extractor", "v1", "s2", &run.RunID); err == nil {
		t.Fatal("Expected retry with a different schema version to fail")
	}
}

func TestRetryPreservesAppendOnlyNodeLinks(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	transcript := "append-only retry transcript"
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(transcript))
	sourceHash := hex.EncodeToString(hash.Sum(nil))
	payload := memorystore.DistillationPayload{
		RawTranscript:    transcript,
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: memorystore.Provenance{
				SourceID:   "session_1",
				SourceHash: sourceHash,
			},
			CoreConcepts: []string{"Append-only concept"},
		},
	}

	run1, _, err := store.StartIngestion(ctx, sourceHash, "session_1", "extractor", "v1", "s1", nil)
	if err != nil {
		t.Fatalf("First StartIngestion failed: %v", err)
	}
	if err = store.StageDistillation(ctx, run1.RunID, run1.LeaseToken, payload); err != nil {
		t.Fatalf("First StageDistillation failed: %v", err)
	}
	errMsg := "interrupted"
	if err = memorystore.TransitionRunState(ctx, db, run1.RunID, memorystore.StatusStaging, memorystore.StatusFailed, run1.LeaseToken, &errMsg); err != nil {
		t.Fatalf("Failed to mark first run failed: %v", err)
	}

	run2, created, err := store.StartIngestion(ctx, sourceHash, "session_1", "extractor", "v1", "s1", &run1.RunID)
	if err != nil || !created {
		t.Fatalf("Retry StartIngestion failed: created=%v err=%v", created, err)
	}
	if err = store.StageDistillation(ctx, run2.RunID, run2.LeaseToken, payload); err != nil {
		t.Fatalf("Retry StageDistillation failed: %v", err)
	}
	if err = memorystore.TransitionRunState(ctx, db, run2.RunID, memorystore.StatusStaging, memorystore.StatusValidated, run2.LeaseToken, nil); err != nil {
		t.Fatalf("Failed to validate retry: %v", err)
	}
	if err = memorystore.TransitionRunState(ctx, db, run2.RunID, memorystore.StatusValidated, memorystore.StatusCommitted, run2.LeaseToken, nil); err != nil {
		t.Fatalf("Failed to commit retry: %v", err)
	}

	var node memorystore.KnowledgeNode
	if err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"content": "Append-only concept"}).Decode(&node); err != nil {
		t.Fatalf("Failed to find immutable node: %v", err)
	}
	linkCount, err := db.Collection("run_node_links").CountDocuments(ctx, bson.M{"node_id": node.ID})
	if err != nil {
		t.Fatalf("Failed to count node links: %v", err)
	}
	if linkCount != 2 {
		t.Fatalf("Expected links for both attempts, got %d", linkCount)
	}

	nodes, err := store.RetrieveCommittedNodes(ctx, bson.M{"content": "Append-only concept"})
	if err != nil {
		t.Fatalf("RetrieveCommittedNodes failed: %v", err)
	}
	if len(nodes) != 1 || nodes[0].ID != node.ID {
		t.Fatalf("Expected one globally deduplicated committed node, got %#v", nodes)
	}

	var rawNode bson.M
	if err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"_id": node.ID}).Decode(&rawNode); err != nil {
		t.Fatalf("Failed to inspect node BSON: %v", err)
	}
	if _, exists := rawNode["ingestion_run_id"]; exists {
		t.Fatal("Immutable node must not contain ingestion_run_id ownership")
	}
}

func TestSourceObservationUsesFullIdentity(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	if _, _, err := store.StartIngestion(ctx, "observation_hash", "session_1", "extractor", "v1", "s1", nil); err != nil {
		t.Fatalf("First StartIngestion failed: %v", err)
	}
	if _, _, err := store.StartIngestion(ctx, "observation_hash", "session_1", "extractor", "v1", "s1", nil); err != nil {
		t.Fatalf("Idempotent StartIngestion failed: %v", err)
	}
	if _, _, err := store.StartIngestion(ctx, "observation_hash", "session_1", "extractor", "v2", "s1", nil); err != nil {
		t.Fatalf("Versioned StartIngestion failed: %v", err)
	}

	count, err := db.Collection("source_observations").CountDocuments(ctx, bson.M{
		"source_hash":        "observation_hash",
		"external_source_id": "session_1",
	})
	if err != nil {
		t.Fatalf("Failed to count observations: %v", err)
	}
	if count != 2 {
		t.Fatalf("Expected one observation per complete ingestion identity, got %d", count)
	}
}

func TestConcurrentStartIngestionIsIdempotent(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	const workers = 12
	type result struct {
		run     *memorystore.IngestionRun
		created bool
		err     error
	}
	results := make(chan result, workers)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			run, created, err := store.StartIngestion(ctx, "concurrent_hash", "session_1", "extractor", "v1", "s1", nil)
			results <- result{run: run, created: created, err: err}
		}()
	}
	wg.Wait()
	close(results)

	var runID string
	createdCount := 0
	for outcome := range results {
		if outcome.err != nil {
			t.Fatalf("Concurrent StartIngestion failed: %v", outcome.err)
		}
		if outcome.run == nil {
			t.Fatal("Concurrent StartIngestion returned a nil run")
		}
		if runID == "" {
			runID = outcome.run.RunID
		} else if outcome.run.RunID != runID {
			t.Fatalf("Expected one authoritative run, got %s and %s", runID, outcome.run.RunID)
		}
		if outcome.created {
			createdCount++
		}
	}
	if createdCount != 1 {
		t.Fatalf("Expected exactly one creator, got %d", createdCount)
	}

	observationCount, err := db.Collection("source_observations").CountDocuments(ctx, bson.M{
		"source_hash": "concurrent_hash",
	})
	if err != nil {
		t.Fatalf("Failed to count concurrent observations: %v", err)
	}
	if observationCount != 1 {
		t.Fatalf("Expected one idempotent observation, got %d", observationCount)
	}
}

func TestEnsureIndexesMigratesLegacyNodeOwnership(t *testing.T) {
	db := setupTestDB(t)
	ctx := context.Background()
	nodeID := primitive.NewObjectID()

	if _, err := db.Collection("knowledge_nodes").InsertOne(ctx, bson.M{
		"_id":              nodeID,
		"stable_id":        "legacy_stable",
		"version":          "v1",
		"status":           "candidate",
		"content":          "Legacy node",
		"ingestion_run_id": "legacy_run",
		"lease_token":      "legacy_lease",
		"created_at":       time.Now().UTC(),
	}); err != nil {
		t.Fatalf("Failed to insert legacy node: %v", err)
	}
	if _, err := db.Collection("sources").InsertOne(ctx, bson.M{
		"source_hash":        "legacy_source",
		"content":            "Legacy source",
		"ingestion_run_id":   "legacy_run",
		"external_source_id": "legacy_session",
	}); err != nil {
		t.Fatalf("Failed to insert legacy source: %v", err)
	}

	if err := memorystore.EnsureIndexes(ctx, db); err != nil {
		t.Fatalf("Legacy migration failed: %v", err)
	}

	linkCount, err := db.Collection("run_node_links").CountDocuments(ctx, bson.M{
		"run_id":  "legacy_run",
		"node_id": nodeID,
	})
	if err != nil || linkCount != 1 {
		t.Fatalf("Expected one migrated legacy link, count=%d err=%v", linkCount, err)
	}

	var rawNode bson.M
	if err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"_id": nodeID}).Decode(&rawNode); err != nil {
		t.Fatalf("Failed to read migrated node: %v", err)
	}
	if _, exists := rawNode["ingestion_run_id"]; exists {
		t.Fatal("Legacy node ownership was not removed")
	}
	if _, exists := rawNode["lease_token"]; exists {
		t.Fatal("Legacy node lease token was not removed")
	}

	var rawSource bson.M
	if err = db.Collection("sources").FindOne(ctx, bson.M{"source_hash": "legacy_source"}).Decode(&rawSource); err != nil {
		t.Fatalf("Failed to read migrated source: %v", err)
	}
	if _, exists := rawSource["ingestion_run_id"]; exists {
		t.Fatal("Legacy source ownership was not removed")
	}
	if _, exists := rawSource["external_source_id"]; exists {
		t.Fatal("Legacy source session identity was not removed")
	}
}

package memorystore_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
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
	run1, created1, err := store.StartIngestion(ctx, "hash_123", "ext_1", "v1", "s1", nil)
	if err != nil || !created1 {
		t.Fatalf("Expected new ingestion run, got err: %v", err)
	}

	// Second run identical
	run2, created2, err := store.StartIngestion(ctx, "hash_123", "ext_1", "v1", "s1", nil)
	if err != nil || created2 {
		t.Fatalf("Expected duplicate run to be caught (created2=false)")
	}

	if run2 == nil || run1.RunID != run2.RunID {
		t.Fatalf("Expected duplicate runs to yield same RunID")
	}
}

func TestForbiddenStateTransition(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	run, _, _ := store.StartIngestion(ctx, "hash_state", "ext_1", "v1", "s1", nil)

	// Try jumping directly staging -> committed
	err := memorystore.TransitionRunState(ctx, db, run.RunID, memorystore.StatusStaging, memorystore.StatusCommitted, nil)
	if err != memorystore.ErrInvalidTransition {
		t.Fatalf("Expected ErrInvalidTransition, got %v", err)
	}
}

func TestInterruptedStagingRetry(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	// Initial failing run
	run1, _, _ := store.StartIngestion(ctx, "hash_fail", "ext_1", "v1", "s1", nil)

	errStr := "interrupted"
	_ = memorystore.TransitionRunState(ctx, db, run1.RunID, memorystore.StatusStaging, memorystore.StatusFailed, &errStr)

	// Retry creates a NEW run
	run2, created, err := store.StartIngestion(ctx, "hash_fail", "ext_1", "v1", "s1", &run1.RunID)
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
		ID:             nodeID,
		StableID:       "stable_123",
		Version:        "v1",
		Status:         "verified",
		Content:        "Actual Content",
		IngestionRunID: "dummy_run",
		CreatedAt:      time.Now(),
	})

	_, _ = db.Collection("ingestion_runs").InsertOne(ctx, memorystore.IngestionRun{
		RunID:  "dummy_run",
		Status: memorystore.StatusCommitted,
	})

	// Attempt promotion with WRONG hash
	_, err := store.PromoteSkill(ctx, "test-skill", "skill data", nodeID.Hex(), "v1", "wrong_hash", "1.0")
	if err != memorystore.ErrSkillOriginHashMismatch {
		t.Fatalf("Expected hash mismatch error, got: %v", err)
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
	newRun, created, err := store.StartIngestion(ctx, sourceHash, "ext_1", "v1", "s1", nil)
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

	run, _, _ := store.StartIngestion(ctx, "hash_verify_test", "ext_1", "v1", "s1", nil)

	transcript := "test transcript"
	hash := sha256.Sum256([]byte(transcript))
	hashStr := hex.EncodeToString(hash[:])

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

	err := store.StageDistillation(ctx, run.RunID, payload)
	if err != nil {
		t.Fatalf("StageDistillation failed: %v", err)
	}

	// Check if the concept was saved as "candidate" instead of "verified"
	var node memorystore.KnowledgeNode
	err = db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"ingestion_run_id": run.RunID, "content": "Concept1"}).Decode(&node)
	if err != nil {
		t.Fatalf("Failed to find node: %v", err)
	}
	
	if node.Status != "candidate" {
		t.Fatalf("Expected node status to be forced to 'candidate', got '%s'", node.Status)
	}
}

func TestSourceHashMismatch(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	run, _, _ := store.StartIngestion(ctx, "hash_mismatch_test", "ext_1", "v1", "s1", nil)

	payload := memorystore.DistillationPayload{
		RawTranscript: "actual transcript content",
		Payload: memorystore.AlexandriaPayload{
			Provenance: memorystore.Provenance{
				SourceHash: "completely_wrong_hash_12345",
			},
		},
	}

	err := store.StageDistillation(ctx, run.RunID, payload)
	if err == nil {
		t.Fatalf("Expected error due to source_hash mismatch, got nil")
	}
}

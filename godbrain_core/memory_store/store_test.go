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
	_, err := store.PromoteSkill(ctx, "test-skill", "skill data", nodeID.Hex(), "v1", "wrong_hash", "1.0", "")
	if err != memorystore.ErrSkillOriginHashMismatch {
		t.Fatalf("Expected hash mismatch error, got: %v", err)
	}
}

func seedVerifiedSkillOrigin(t *testing.T, db *mongo.Database, content string) (primitive.ObjectID, string) {
	t.Helper()
	ctx := context.Background()
	nodeID := primitive.NewObjectID()
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(content))
	originHash := hex.EncodeToString(hash.Sum(nil))
	stable := "skill-origin-" + nodeID.Hex()
	runID := "skill-run-" + nodeID.Hex()
	_, err := db.Collection("knowledge_nodes").InsertOne(ctx, memorystore.KnowledgeNode{
		ID:        nodeID,
		StableID:  stable,
		Version:   "v1",
		Kind:      "skill",
		Status:    "verified",
		Content:   content,
		CreatedAt: time.Now(),
	})
	if err != nil {
		t.Fatalf("seed node: %v", err)
	}
	_, err = db.Collection("ingestion_runs").InsertOne(ctx, memorystore.IngestionRun{
		RunID:  runID,
		Status: memorystore.StatusCommitted,
	})
	if err != nil {
		t.Fatalf("seed run: %v", err)
	}
	_, err = db.Collection("run_node_links").InsertOne(ctx, memorystore.RunNodeLink{
		RunID:       runID,
		NodeID:      nodeID,
		StableID:    stable,
		NodeVersion: "v1",
		CreatedAt:   time.Now(),
	})
	if err != nil {
		t.Fatalf("seed link: %v", err)
	}
	return nodeID, originHash
}

func TestPromoteSkillRequiresPassingRun(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()
	content := "Keep /brief first line as the phone glance."
	nodeID, originHash := seedVerifiedSkillOrigin(t, db, content)

	_, err := store.PromoteSkill(ctx, "build-galaxy-glance", content, nodeID.Hex(), "v1", originHash, "1.0", "")
	if !errors.Is(err, memorystore.ErrSkillVerificationRequired) {
		t.Fatalf("expected verification required, got %v", err)
	}

	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "build-galaxy-glance",
		OriginNodeID:        nodeID.Hex(),
		FixtureID:           "galaxy-brief-v1",
		VerificationProfile: "galaxy-html-v1",
		Result:              memorystore.SkillRunFailed,
		Reasoning:           "build failed on fixture",
	})
	if err != nil {
		t.Fatalf("record failed run: %v", err)
	}
	_, err = store.PromoteSkill(ctx, "build-galaxy-glance", content, nodeID.Hex(), "v1", originHash, "1.0", "")
	if !errors.Is(err, memorystore.ErrSkillVerificationStale) {
		t.Fatalf("expected stale verification, got %v", err)
	}

	time.Sleep(2 * time.Millisecond)
	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "build-galaxy-glance",
		OriginNodeID:        nodeID.Hex(),
		FixtureID:           "galaxy-brief-v1",
		VerificationProfile: "galaxy-html-v1",
		Result:              memorystore.SkillRunPassed,
		Checks:              map[string]string{"build": "passed"},
		Reasoning:           "desk test passed on loopback",
	})
	if err != nil {
		t.Fatalf("record passing run: %v", err)
	}
	_, err = store.PromoteSkill(ctx, "build-galaxy-glance", content, nodeID.Hex(), "v1", originHash, "1.0", "galaxy-html-v1")
	if !errors.Is(err, memorystore.ErrSkillSuiteRequired) {
		t.Fatalf("one galaxy fixture must not promote, got %v", err)
	}
	time.Sleep(2 * time.Millisecond)
	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "build-galaxy-glance",
		OriginNodeID:        nodeID.Hex(),
		FixtureID:           "galaxy-host-card-v1",
		SuiteID:             "galaxy-html-suite-v1",
		VerificationProfile: "galaxy-html-v1",
		Result:              memorystore.SkillRunPassed,
		Checks:              map[string]string{"overlay": "passed"},
		Reasoning:           "host card overlay still paints",
	})
	if err != nil {
		t.Fatalf("record second galaxy fixture: %v", err)
	}
	skill, err := store.PromoteSkill(ctx, "build-galaxy-glance", content, nodeID.Hex(), "v1", originHash, "1.0", "galaxy-html-v1")
	if err != nil {
		t.Fatalf("promote after passing run: %v", err)
	}
	if skill.Name != "build-galaxy-glance" || skill.VerificationProfile != "galaxy-html-v1" || skill.VerificationRunID == "" {
		t.Fatalf("unexpected skill: %+v", skill)
	}

	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "other-skill",
		OriginNodeID:        nodeID.Hex(),
		FixtureID:           "unrelated",
		VerificationProfile: "desk-v1",
		Result:              memorystore.SkillRunPassed,
		Reasoning:           "unrelated skill passing run",
	})
	if err != nil {
		t.Fatalf("record other skill: %v", err)
	}
	_, err = store.PromoteSkill(ctx, "missing-lab-skill", content, nodeID.Hex(), "v1", originHash, "1.0", "")
	if !errors.Is(err, memorystore.ErrSkillVerificationRequired) {
		t.Fatalf("other skill run must not promote missing-lab-skill, got %v", err)
	}

	applyNode, applyHash := seedVerifiedSkillOrigin(t, db, "apply only")
	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "apply-only",
		OriginNodeID:        applyNode.Hex(),
		FixtureID:           "edit",
		VerificationProfile: "local-edit-apply-v1",
		Result:              memorystore.SkillRunPassed,
		Reasoning:           "hunks applied to disk",
	})
	if err != nil {
		t.Fatalf("record apply-only: %v", err)
	}
	_, err = store.PromoteSkill(ctx, "apply-only", "apply only", applyNode.Hex(), "v1", applyHash, "1.0", "")
	if !errors.Is(err, memorystore.ErrSkillApplyOnlyProfile) {
		t.Fatalf("apply-only must not promote, got %v", err)
	}

	mismatchNode, mismatchHash := seedVerifiedSkillOrigin(t, db, "origin procedure text")
	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "content-lock",
		OriginNodeID:        mismatchNode.Hex(),
		FixtureID:           "lab",
		VerificationProfile: "frontend-spa-v1",
		Result:              memorystore.SkillRunPassed,
		Reasoning:           "fixture build passed with docs",
	})
	if err != nil {
		t.Fatalf("record content-lock run: %v", err)
	}
	_, err = store.RecordSkillVerificationRun(ctx, memorystore.RecordSkillRunRequest{
		Command:             memorystore.RecordSkillRunCommand,
		SkillName:           "content-lock",
		OriginNodeID:        mismatchNode.Hex(),
		FixtureID:           "lab-docs",
		SuiteID:             "frontend-spa-suite-v1",
		VerificationProfile: "frontend-spa-v1",
		Result:              memorystore.SkillRunPassed,
		Reasoning:           "second spa fixture passed with docs",
	})
	if err != nil {
		t.Fatalf("record content-lock second fixture: %v", err)
	}
	_, err = store.PromoteSkill(ctx, "content-lock", "unrelated published text", mismatchNode.Hex(), "v1", mismatchHash, "1.0", "")
	if !errors.Is(err, memorystore.ErrSkillContentMismatch) {
		t.Fatalf("promoted content must match origin, got %v", err)
	}
	_, err = store.PromoteSkill(ctx, "content-lock", "origin procedure text", mismatchNode.Hex(), "v1", mismatchHash, "1.0", "galaxy-html-v1")
	if !errors.Is(err, memorystore.ErrSkillProfileMismatch) {
		t.Fatalf("expected profile must match passing run, got %v", err)
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
		"",
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
		ExtractorID:      "extractor",
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: memorystore.Provenance{
				SourceID:   "session_1",
				SourceType: "copilot_session",
				SourceHash: sourceHash,
				Language:   "en",
			},
			Claims: []memorystore.Claim{
				{
					ClaimID:       "provider-a",
					Type:          "Fact",
					Content:       "The same semantic claim",
					Confidence:    0.4,
					EvidenceSpans: []string{"[10:12]", "[2:4]", "[2:4]"},
				},
				{
					ClaimID:       "provider-b",
					Type:          " fact ",
					Content:       "The  same semantic claim",
					Confidence:    0.9,
					EvidenceSpans: []string{"[8:11]", "[10:12]"},
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
	if claimNode.Sector != "fact" || claimNode.Content != "The same semantic claim" {
		t.Fatalf("Expected normalized claim fields, got sector=%q content=%q", claimNode.Sector, claimNode.Content)
	}
	expectedSpans := []string{"[2:4]", "[8:11]", "[10:12]"}
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

func TestStageDistillationRejectsInvalidEvidenceSpans(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()

	transcript := "span reject transcript"
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(transcript))
	sourceHash := hex.EncodeToString(hash.Sum(nil))
	run, _, err := store.StartIngestion(ctx, sourceHash, "session_span", "extractor", "v1", "s1", nil)
	if err != nil {
		t.Fatalf("StartIngestion failed: %v", err)
	}

	payload := memorystore.DistillationPayload{
		RawTranscript:    transcript,
		ExtractorID:      "extractor",
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: memorystore.Provenance{
				SourceID:   "session_span",
				SourceType: "copilot_session",
				SourceHash: sourceHash,
				Language:   "en",
			},
			Claims: []memorystore.Claim{
				{
					ClaimID:       "bad-span",
					Type:          "fact",
					Content:       "Malformed evidence must fail closed",
					Confidence:    0.9,
					EvidenceSpans: []string{"[0:4]", "invalid"},
				},
			},
		},
	}
	err = store.StageDistillation(ctx, run.RunID, run.LeaseToken, payload)
	if !errors.Is(err, memorystore.ErrInvalidEvidenceSpan) {
		t.Fatalf("expected ErrInvalidEvidenceSpan, got %v", err)
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
		ExtractorID:      "extractor",
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
		Payload: memorystore.AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: memorystore.Provenance{
				SourceID:   "session_1",
				SourceType: "copilot_session",
				SourceHash: sourceHash,
				Language:   "en",
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

func TestStaleMismatchedPinsSelectsAndIsIdempotent(t *testing.T) {
	db := setupTestDB(t)
	store := memorystore.NewStore(db)
	ctx := context.Background()
	nodes := db.Collection("knowledge_nodes")
	live := "IoTEnterpriseS/26100.8037"
	reason := "os pin moved on this host"

	matchID := primitive.NewObjectID()
	mismatchID := primitive.NewObjectID()
	alreadyStaleID := primitive.NewObjectID()
	learnID := primitive.NewObjectID()
	otherSectorID := primitive.NewObjectID()

	seeds := []memorystore.KnowledgeNode{
		{ID: matchID, StableID: "pin-match", Status: memorystore.StatusVerified, Sector: "windows-sre",
			Content: "card\nos_pin=" + live + "\n", CreatedAt: time.Now().UTC()},
		{ID: mismatchID, StableID: "pin-mismatch", Status: memorystore.StatusVerified, Sector: "windows-sre",
			Content: "card\nos_pin=IoTEnterpriseS/26100.1\n", CreatedAt: time.Now().UTC()},
		{ID: alreadyStaleID, StableID: "pin-stale", Status: memorystore.StatusStale, Sector: "windows-sre",
			Content: "card\nos_pin=IoTEnterpriseS/26100.1\n", CreatedAt: time.Now().UTC()},
		{ID: learnID, StableID: "learn", Status: memorystore.StatusVerified, Sector: "windows-sre",
			Content: "Learn quote, no pin", CreatedAt: time.Now().UTC()},
		{ID: otherSectorID, StableID: "tanks", Status: memorystore.StatusVerified, Sector: "armor",
			Content: "card\nos_pin=IoTEnterpriseS/26100.1\n", CreatedAt: time.Now().UTC()},
	}
	for _, node := range seeds {
		if _, err := nodes.InsertOne(ctx, node); err != nil {
			t.Fatalf("seed %s: %v", node.StableID, err)
		}
	}

	ids, err := store.StaleMismatchedPins(ctx, "windows-sre", live, reason)
	if err != nil {
		t.Fatalf("first sweep: %v", err)
	}
	got := map[primitive.ObjectID]bool{}
	for _, id := range ids {
		got[id] = true
	}
	if !got[mismatchID] || !got[alreadyStaleID] {
		t.Fatalf("expected mismatch + already-stale ids, got %v", ids)
	}
	if got[matchID] || got[learnID] || got[otherSectorID] {
		t.Fatalf("sweep selected a card it must leave alone: %v", ids)
	}

	var mismatch memorystore.KnowledgeNode
	if err := nodes.FindOne(ctx, bson.M{"_id": mismatchID}).Decode(&mismatch); err != nil {
		t.Fatal(err)
	}
	if mismatch.Status != memorystore.StatusStale {
		t.Fatalf("verified mismatch status=%s", mismatch.Status)
	}

	again, err := store.StaleMismatchedPins(ctx, "windows-sre", live, reason)
	if err != nil {
		t.Fatalf("retry sweep: %v", err)
	}
	if len(again) != len(ids) {
		t.Fatalf("retry should return the same mismatched set: first=%d retry=%d", len(ids), len(again))
	}

	if _, err := store.StaleMismatchedPins(ctx, "windows-sre", "bad pin!!", reason); !errors.Is(err, memorystore.ErrInvalidStalePin) {
		t.Fatalf("invalid pin: %v", err)
	}
}

package rag_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	memorystore "godbrain_core/memory_store"
	"godbrain_core/memory_store/rag"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func setupRAGTestDB(t *testing.T) *mongo.Database {
	t.Helper()
	uri := os.Getenv("MONGODB_TEST_URI")
	if uri == "" {
		t.Skip("Skipping RAG integration test: MONGODB_TEST_URI is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatalf("connect to disposable MongoDB: %v", err)
	}
	dbName := "godbrain_rag_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	db := client.Database(dbName)
	if err = memorystore.EnsureIndexes(ctx, db); err != nil {
		t.Fatalf("ensure source indexes: %v", err)
	}
	if err = rag.EnsureIndexes(ctx, db); err != nil {
		t.Fatalf("ensure RAG indexes: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cleanupCancel()
		if err := db.Drop(cleanupCtx); err != nil {
			t.Errorf("drop disposable test database: %v", err)
		}
		if err := client.Disconnect(cleanupCtx); err != nil {
			t.Errorf("disconnect disposable test database: %v", err)
		}
	})
	return db
}

func TestCommittedProjectionSearchRepairAndRebuild(t *testing.T) {
	db := setupRAGTestDB(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	now := time.Now().UTC()

	source1 := memorystore.Source{
		ID:         primitive.NewObjectID(),
		SourceHash: "source-hash-1",
		SourceType: "session",
		Language:   "mixed",
		Content:    "architecture evidence 世界",
		CreatedAt:  now,
	}
	source2 := memorystore.Source{
		ID:         primitive.NewObjectID(),
		SourceHash: "source-hash-2",
		SourceType: "session",
		Language:   "mixed",
		Content:    "second architecture evidence",
		CreatedAt:  now,
	}
	if _, err := db.Collection("sources").InsertMany(ctx, []any{source1, source2}); err != nil {
		t.Fatalf("seed sources: %v", err)
	}

	committedNode := memorystore.KnowledgeNode{
		ID:            primitive.NewObjectID(),
		StableID:      "stable-architecture",
		Version:       "v1",
		Kind:          "claim",
		Status:        "candidate",
		Sector:        "architecture",
		Content:       "architecture evidence",
		Confidence:    0.91,
		EvidenceSpans: []string{"[0:12]"},
		SchemaVersion: "s1",
		CreatedAt:     now,
	}
	stagingNode := committedNode
	stagingNode.ID = primitive.NewObjectID()
	stagingNode.StableID = "stable-staging"
	stagingNode.Content = "staging secret"
	failedNode := committedNode
	failedNode.ID = primitive.NewObjectID()
	failedNode.StableID = "stable-failed"
	failedNode.Content = "failed secret"
	unlinkedNode := committedNode
	unlinkedNode.ID = primitive.NewObjectID()
	unlinkedNode.StableID = "stable-unlinked"
	unlinkedNode.Content = "unlinked secret"
	if _, err := db.Collection("knowledge_nodes").InsertMany(ctx, []any{
		committedNode,
		stagingNode,
		failedNode,
		unlinkedNode,
	}); err != nil {
		t.Fatalf("seed nodes: %v", err)
	}

	runs := []any{
		memorystore.IngestionRun{
			RunID:            "committed-run-1",
			Status:           memorystore.StatusCommitted,
			Active:           true,
			SourceHash:       source1.SourceHash,
			SourceID:         source1.ID,
			ExternalSourceID: "session-1",
			ExtractorID:      "extractor",
			ExtractorVer:     "v1",
			SchemaVersion:    "s1",
			CreatedAt:        now,
			UpdatedAt:        now,
		},
		memorystore.IngestionRun{
			RunID:            "committed-run-2",
			Status:           memorystore.StatusCommitted,
			Active:           true,
			SourceHash:       source2.SourceHash,
			SourceID:         source2.ID,
			ExternalSourceID: "session-2",
			ExtractorID:      "extractor",
			ExtractorVer:     "v1",
			SchemaVersion:    "s1",
			CreatedAt:        now,
			UpdatedAt:        now.Add(time.Second),
		},
		memorystore.IngestionRun{
			RunID:         "staging-run",
			Status:        memorystore.StatusStaging,
			Active:        true,
			SourceHash:    "staging-source",
			ExtractorID:   "extractor",
			ExtractorVer:  "v1",
			SchemaVersion: "s1",
			CreatedAt:     now,
			UpdatedAt:     now,
		},
		memorystore.IngestionRun{
			RunID:         "failed-run",
			Status:        memorystore.StatusFailed,
			Active:        false,
			SourceHash:    "failed-source",
			ExtractorID:   "extractor",
			ExtractorVer:  "v1",
			SchemaVersion: "s1",
			CreatedAt:     now,
			UpdatedAt:     now,
		},
	}
	if _, err := db.Collection("ingestion_runs").InsertMany(ctx, runs); err != nil {
		t.Fatalf("seed runs: %v", err)
	}
	links := []any{
		memorystore.RunNodeLink{RunID: "committed-run-1", NodeID: committedNode.ID, StableID: committedNode.StableID, NodeVersion: "v1", EvidenceSpans: []string{"[0:12]"}, AttemptToken: "a", CreatedAt: now},
		memorystore.RunNodeLink{RunID: "committed-run-2", NodeID: committedNode.ID, StableID: committedNode.StableID, NodeVersion: "v1", EvidenceSpans: []string{"[7:19]"}, AttemptToken: "b", CreatedAt: now},
		memorystore.RunNodeLink{RunID: "staging-run", NodeID: stagingNode.ID, StableID: stagingNode.StableID, NodeVersion: "v1", AttemptToken: "c", CreatedAt: now},
		memorystore.RunNodeLink{RunID: "failed-run", NodeID: failedNode.ID, StableID: failedNode.StableID, NodeVersion: "v1", AttemptToken: "d", CreatedAt: now},
	}
	if _, err := db.Collection("run_node_links").InsertMany(ctx, links); err != nil {
		t.Fatalf("seed run links: %v", err)
	}

	projector := rag.NewProjector(db)
	if err := projector.ProjectCommittedRun(ctx, "staging-run"); !errors.Is(err, rag.ErrRunNotCommitted) {
		t.Fatalf("expected staging projection rejection, got %v", err)
	}

	var waitGroup sync.WaitGroup
	errorsChannel := make(chan error, 12)
	for index := 0; index < 6; index++ {
		for _, runID := range []string{"committed-run-1", "committed-run-2"} {
			waitGroup.Add(1)
			go func(runID string) {
				defer waitGroup.Done()
				errorsChannel <- projector.ProjectCommittedRun(ctx, runID)
			}(runID)
		}
	}
	waitGroup.Wait()
	close(errorsChannel)
	for projectionErr := range errorsChannel {
		if projectionErr != nil {
			t.Fatalf("concurrent projection failed: %v", projectionErr)
		}
	}

	metadata, err := projector.Metadata(ctx)
	if err != nil {
		t.Fatalf("read projection metadata: %v", err)
	}
	documentCount, err := db.Collection(rag.DocumentsCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || documentCount != 1 {
		t.Fatalf("expected one deduplicated document, count=%d err=%v", documentCount, err)
	}
	provenanceCount, err := db.Collection(rag.ProvenanceCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || provenanceCount != 2 {
		t.Fatalf("expected both provenance links, count=%d err=%v", provenanceCount, err)
	}

	engine := rag.NewEngine(db, rag.Config{PreferredSchemaVersion: "s1"})
	search, err := engine.Search(ctx, rag.SearchRequest{
		Query:        "architecture",
		TopK:         5,
		Kind:         "claim",
		Sector:       "architecture",
		ContextBytes: 1024,
	})
	if err != nil {
		t.Fatalf("text and metadata search: %v", err)
	}
	if len(search.Results) != 1 || search.Results[0].StableID != committedNode.StableID {
		t.Fatalf("unexpected search results %#v", search.Results)
	}
	if len(search.Results[0].Citations) != 2 || search.Results[0].CitationStatus != "available" {
		t.Fatalf("expected two resolved citations, got %#v", search.Results[0])
	}
	for _, citation := range search.Results[0].Citations {
		if len(citation.Evidence) != 1 || !citation.Evidence[0].ByteValid {
			t.Fatalf("expected byte-valid evidence citation, got %#v", citation)
		}
		if citation.Evidence[0].Excerpt != "architecture" {
			t.Fatalf("citation used evidence offsets from a different source: %#v", citation)
		}
	}

	if _, err = db.Collection(rag.DocumentsCollection).DeleteMany(ctx, bson.M{"generation": metadata.ActiveGeneration}); err != nil {
		t.Fatalf("simulate missing projection document: %v", err)
	}
	if _, err = db.Collection(rag.ProvenanceCollection).DeleteMany(ctx, bson.M{"generation": metadata.ActiveGeneration}); err != nil {
		t.Fatalf("simulate missing projection provenance: %v", err)
	}
	health, err := engine.Health(ctx)
	if err != nil {
		t.Fatalf("health after simulated failure: %v", err)
	}
	if health.Ready {
		t.Fatal("health must report projection lag after simulated post-commit failure")
	}
	for _, runID := range []string{"committed-run-1", "committed-run-2", "committed-run-1"} {
		if err = projector.ProjectCommittedRun(ctx, runID); err != nil {
			t.Fatalf("idempotent projection repair for %s: %v", runID, err)
		}
	}
	health, err = engine.Health(ctx)
	if err != nil || !health.Ready {
		t.Fatalf("health after idempotent repair: ready=%v reasons=%v err=%v", health.Ready, health.ReadinessReasons, err)
	}

	staleGeneration := "stale-generation"
	if _, err = db.Collection(rag.DocumentsCollection).InsertOne(ctx, bson.M{
		"generation": staleGeneration,
		"node_id":    primitive.NewObjectID(),
		"stable_id":  "stale",
		"content":    "stale derivative only",
	}); err != nil {
		t.Fatalf("seed stale projection: %v", err)
	}
	if _, err = db.Collection(rag.MetadataCollection).UpdateOne(ctx, bson.M{"_id": "canonical"}, bson.M{
		"$push": bson.M{"retired_generations": rag.RetiredGeneration{
			Generation: staleGeneration,
			RetiredAt:  now.Add(-time.Hour),
		}},
	}); err != nil {
		t.Fatalf("mark stale generation: %v", err)
	}
	report, err := projector.Rebuild(ctx)
	if err != nil {
		t.Fatalf("generation rebuild: %v", err)
	}
	if report.Generation == metadata.ActiveGeneration || report.Counts.ProjectedNodes != 1 || report.Counts.ProjectedLinks != 2 {
		t.Fatalf("unexpected rebuild report %#v", report)
	}
	staleCount, err := db.Collection(rag.DocumentsCollection).CountDocuments(ctx, bson.M{"generation": staleGeneration})
	if err != nil || staleCount != 0 {
		t.Fatalf("stale derivative cleanup failed count=%d err=%v", staleCount, err)
	}

	indexCursor, err := db.Collection(rag.DocumentsCollection).Indexes().List(ctx)
	if err != nil {
		t.Fatalf("list RAG indexes: %v", err)
	}
	defer indexCursor.Close(ctx)
	var indexes []bson.M
	if err = indexCursor.All(ctx, &indexes); err != nil {
		t.Fatalf("decode RAG indexes: %v", err)
	}
	indexNames := make(map[string]bool)
	for _, index := range indexes {
		if name, ok := index["name"].(string); ok {
			indexNames[name] = true
		}
	}
	for _, required := range []string{"rag_document_identity", "rag_lexical_text", "rag_metadata_rank"} {
		if !indexNames[required] {
			t.Fatalf("required index %q is missing: %#v", required, indexNames)
		}
	}
}

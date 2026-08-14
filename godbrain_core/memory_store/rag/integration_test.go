package rag_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
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

type hookedSearchAPI struct {
	engine   *rag.Engine
	hook     func(context.Context) error
	once     sync.Once
	hookErr  error
	observed rag.SearchResponse
}

func (api *hookedSearchAPI) Health(ctx context.Context) (rag.HealthResponse, error) {
	return api.engine.Health(ctx)
}

func (api *hookedSearchAPI) Search(ctx context.Context, request rag.SearchRequest) (rag.SearchResponse, error) {
	api.once.Do(func() {
		api.hookErr = api.hook(ctx)
	})
	if api.hookErr != nil {
		return rag.SearchResponse{}, api.hookErr
	}
	response, err := api.engine.Search(ctx, request)
	api.observed = response
	return response, err
}

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

func TestHTTPSearchRejectsDocumentBeforeProvenanceInterleaving(t *testing.T) {
	db := setupRAGTestDB(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	now := time.Now().UTC()

	stableSource := memorystore.Source{
		ID: primitive.NewObjectID(), SourceHash: "stable-source", SourceType: "session",
		Language: "en", Content: "stable evidence", CreatedAt: now,
	}
	partialSource := memorystore.Source{
		ID: primitive.NewObjectID(), SourceHash: "partial-source", SourceType: "session",
		Language: "en", Content: "interleaving evidence", CreatedAt: now,
	}
	stableNode := memorystore.KnowledgeNode{
		ID: primitive.NewObjectID(), StableID: "stable-node", Version: "v1", Kind: "claim",
		Status: "candidate", Sector: "architecture", Content: "stable lexical context",
		Confidence: 0.9, EvidenceSpans: []string{"[0:6]"}, SchemaVersion: "s1", CreatedAt: now,
	}
	partialNode := memorystore.KnowledgeNode{
		ID: primitive.NewObjectID(), StableID: "partial-node", Version: "v1", Kind: "claim",
		Status: "candidate", Sector: "architecture", Content: "interleaving partial context",
		Confidence: 0.9, EvidenceSpans: []string{"[0:12]"}, SchemaVersion: "s1", CreatedAt: now,
	}
	if _, err := db.Collection("sources").InsertMany(ctx, []any{stableSource, partialSource}); err != nil {
		t.Fatalf("seed sources: %v", err)
	}
	if _, err := db.Collection("knowledge_nodes").InsertMany(ctx, []any{stableNode, partialNode}); err != nil {
		t.Fatalf("seed nodes: %v", err)
	}
	stableRun := memorystore.IngestionRun{
		RunID: "stable-run", Status: memorystore.StatusCommitted, Active: true,
		SourceHash: stableSource.SourceHash, SourceID: stableSource.ID, ExternalSourceID: "stable-session",
		ExtractorID: "extractor", ExtractorVer: "v1", SchemaVersion: "s1", CreatedAt: now, UpdatedAt: now,
	}
	partialRun := memorystore.IngestionRun{
		RunID: "partial-run", Status: memorystore.StatusStaging, Active: true,
		SourceHash: partialSource.SourceHash, SourceID: partialSource.ID, ExternalSourceID: "partial-session",
		ExtractorID: "extractor", ExtractorVer: "v1", SchemaVersion: "s1", CreatedAt: now, UpdatedAt: now,
	}
	if _, err := db.Collection("ingestion_runs").InsertMany(ctx, []any{stableRun, partialRun}); err != nil {
		t.Fatalf("seed runs: %v", err)
	}
	if _, err := db.Collection("run_node_links").InsertMany(ctx, []any{
		memorystore.RunNodeLink{RunID: stableRun.RunID, NodeID: stableNode.ID, StableID: stableNode.StableID, NodeVersion: "v1", EvidenceSpans: []string{"[0:6]"}, AttemptToken: "stable", CreatedAt: now},
		memorystore.RunNodeLink{RunID: partialRun.RunID, NodeID: partialNode.ID, StableID: partialNode.StableID, NodeVersion: "v1", EvidenceSpans: []string{"[0:12]"}, AttemptToken: "partial", CreatedAt: now},
	}); err != nil {
		t.Fatalf("seed links: %v", err)
	}

	projector := rag.NewProjector(db)
	if err := projector.ProjectCommittedRun(ctx, stableRun.RunID); err != nil {
		t.Fatalf("project stable run: %v", err)
	}
	metadata, err := projector.Metadata(ctx)
	if err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	engine := rag.NewEngine(db, rag.Config{PreferredSchemaVersion: "s1"})
	api := &hookedSearchAPI{
		engine: engine,
		hook: func(hookCtx context.Context) error {
			committedAt := now.Add(time.Second)
			if _, updateErr := db.Collection("ingestion_runs").UpdateOne(
				hookCtx,
				bson.M{"run_id": partialRun.RunID, "status": memorystore.StatusStaging},
				bson.M{"$set": bson.M{"status": memorystore.StatusCommitted, "updated_at": committedAt}},
			); updateErr != nil {
				return updateErr
			}
			_, insertErr := db.Collection(rag.DocumentsCollection).InsertOne(hookCtx, rag.Document{
				Generation: metadata.ActiveGeneration, NodeID: partialNode.ID, StableID: partialNode.StableID,
				NodeVersion: partialNode.Version, Content: partialNode.Content, Kind: partialNode.Kind,
				Sector: partialNode.Sector, Status: partialNode.Status, Confidence: partialNode.Confidence,
				SchemaVersion: partialNode.SchemaVersion, EvidenceSpans: partialNode.EvidenceSpans,
				NodeCreatedAt: partialNode.CreatedAt, ProjectionVersion: rag.ProjectionVersion,
				ProjectionSchema: rag.ProjectionSchema, IndexerVersion: rag.IndexerVersion, ProjectedAt: committedAt,
			})
			return insertErr
		},
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"interleaving"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	rag.NewHandler(api).ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for document-before-provenance interleaving, got %d body=%s", response.Code, response.Body.String())
	}
	if len(api.observed.Results) != 1 || api.observed.Results[0].CitationStatus != "missing_provenance" {
		t.Fatalf("test did not force a partial search result: %#v", api.observed.Results)
	}
	if strings.Contains(response.Body.String(), partialNode.Content) {
		t.Fatal("partial context escaped into the HTTP response")
	}

	if err := projector.ProjectCommittedRun(ctx, partialRun.RunID); err != nil {
		t.Fatalf("repair partial projection: %v", err)
	}
	request = httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"interleaving"}`))
	request.Header.Set("Content-Type", "application/json")
	response = httptest.NewRecorder()
	rag.NewHandler(engine).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected stable repaired search success, got %d body=%s", response.Code, response.Body.String())
	}
	var search rag.SearchResponse
	if err := json.NewDecoder(response.Body).Decode(&search); err != nil {
		t.Fatalf("decode repaired search: %v", err)
	}
	if len(search.Results) != 1 || search.Results[0].CitationStatus != "available" || len(search.Results[0].Citations) != 1 {
		t.Fatalf("expected repaired citation-complete result, got %#v", search.Results)
	}
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

	t.Run("hybrid projection search and rebuild remain committed only", func(t *testing.T) {
		db := setupRAGTestDB(t)
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		fake, err := rag.NewDeterministicFakeProvider(64)
		if err != nil {
			t.Fatalf("create deterministic embedding provider: %v", err)
		}
		runtime := rag.EmbeddingRuntime{Provider: fake, Required: true}
		identity := fake.Identity()
		if _, err = db.Collection(rag.MetadataCollection).UpdateOne(
			ctx,
			bson.M{"_id": "canonical"},
			bson.M{"$set": bson.M{"embedding": identity}},
		); err != nil {
			t.Fatalf("configure active embedding identity: %v", err)
		}

		now := time.Unix(1_750_000_000, 0).UTC()
		source := memorystore.Source{
			ID: primitive.NewObjectID(), SourceHash: "hybrid-source", SourceType: "session",
			Language: "en", Content: "bearer authentication guard", CreatedAt: now,
		}
		committedNode := memorystore.KnowledgeNode{
			ID: primitive.NewObjectID(), StableID: "hybrid-auth-guard", Version: "v1",
			Kind: "claim", Status: "candidate", Sector: "security",
			Content: "bearer authentication guard", Confidence: 0.9,
			SchemaVersion: "s1", CreatedAt: now,
		}
		hiddenNode := memorystore.KnowledgeNode{
			ID: primitive.NewObjectID(), StableID: "hidden-auth-secret", Version: "v1",
			Kind: "claim", Status: "candidate", Sector: "security",
			Content: "credential authorization hidden secret", Confidence: 1,
			SchemaVersion: "s1", CreatedAt: now,
		}
		if _, err = db.Collection("sources").InsertOne(ctx, source); err != nil {
			t.Fatalf("seed hybrid source: %v", err)
		}
		if _, err = db.Collection("knowledge_nodes").InsertMany(ctx, []any{committedNode, hiddenNode}); err != nil {
			t.Fatalf("seed hybrid nodes: %v", err)
		}
		committedRun := memorystore.IngestionRun{
			RunID: "hybrid-committed-run", Status: memorystore.StatusCommitted, Active: true,
			SourceHash: source.SourceHash, SourceID: source.ID, ExternalSourceID: "fixture://hybrid",
			ExtractorID: "fixture", ExtractorVer: "v1", SchemaVersion: "s1",
			CreatedAt: now, UpdatedAt: now,
		}
		hiddenRun := memorystore.IngestionRun{
			RunID: "hybrid-staging-run", Status: memorystore.StatusStaging, Active: true,
			SourceHash: "hidden-source", ExtractorID: "fixture", ExtractorVer: "v1",
			SchemaVersion: "s1", CreatedAt: now, UpdatedAt: now,
		}
		if _, err = db.Collection("ingestion_runs").InsertMany(ctx, []any{committedRun, hiddenRun}); err != nil {
			t.Fatalf("seed hybrid runs: %v", err)
		}
		if _, err = db.Collection("run_node_links").InsertMany(ctx, []any{
			memorystore.RunNodeLink{
				RunID: committedRun.RunID, NodeID: committedNode.ID, StableID: committedNode.StableID,
				NodeVersion: "v1", EvidenceSpans: []string{"[0:6]"}, AttemptToken: "committed", CreatedAt: now,
			},
			memorystore.RunNodeLink{
				RunID: hiddenRun.RunID, NodeID: hiddenNode.ID, StableID: hiddenNode.StableID,
				NodeVersion: "v1", AttemptToken: "staging", CreatedAt: now,
			},
		}); err != nil {
			t.Fatalf("seed hybrid links: %v", err)
		}

		projector := rag.NewProjector(db, runtime)
		if err = projector.ProjectCommittedRun(ctx, committedRun.RunID); err != nil {
			t.Fatalf("project committed hybrid run: %v", err)
		}
		if err = projector.ProjectCommittedRun(ctx, hiddenRun.RunID); !errors.Is(err, rag.ErrRunNotCommitted) {
			t.Fatalf("staging hybrid projection must fail closed, got %v", err)
		}
		metadata, err := projector.Metadata(ctx)
		if err != nil {
			t.Fatal(err)
		}
		embeddingCount, err := db.Collection(rag.EmbeddingsCollection).CountDocuments(
			ctx,
			bson.M{"generation": metadata.ActiveGeneration},
		)
		if err != nil || embeddingCount != 1 {
			t.Fatalf("expected exactly one committed embedding, count=%d err=%v", embeddingCount, err)
		}

		engine := rag.NewEngine(db, rag.Config{
			PreferredSchemaVersion: "s1",
			EmbeddingRuntime:       runtime,
		})
		lexical, err := engine.Search(ctx, rag.SearchRequest{
			Query: "credential authorization", TopK: 5, ContextBytes: 1024,
			RetrievalMode: "lexical",
		})
		if err != nil {
			t.Fatalf("lexical control search: %v", err)
		}
		if len(lexical.Results) != 0 || lexical.RetrievalMode != "lexical" {
			t.Fatalf("lexical control unexpectedly matched paraphrase: %#v", lexical)
		}
		hybrid, err := engine.Search(ctx, rag.SearchRequest{
			Query: "credential authorization", TopK: 5, ContextBytes: 1024,
			RetrievalMode: "hybrid",
		})
		if err != nil {
			t.Fatalf("hybrid paraphrase search: %v", err)
		}
		if hybrid.RetrievalMode != "hybrid" ||
			hybrid.Embedding == nil ||
			len(hybrid.Results) != 1 ||
			hybrid.Results[0].StableID != committedNode.StableID ||
			hybrid.Results[0].CitationStatus != "available" {
			t.Fatalf("unexpected hybrid paraphrase result %#v", hybrid)
		}
		if strings.Contains(hybrid.Results[0].Snippet, "hidden secret") {
			t.Fatal("staging content leaked through semantic retrieval")
		}

		report, err := projector.Rebuild(ctx)
		if err != nil {
			t.Fatalf("hybrid rebuild: %v", err)
		}
		if report.Counts.ProjectedEmbeddings != 1 ||
			report.Counts.ProjectedNodes != 1 ||
			report.Generation == metadata.ActiveGeneration {
			t.Fatalf("unexpected hybrid rebuild report %#v", report)
		}
		rebuiltMetadata, err := projector.Metadata(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if rebuiltMetadata.ActiveGeneration != report.Generation ||
			rebuiltMetadata.Embedding == nil ||
			!rebuiltMetadata.Embedding.Equal(identity) {
			t.Fatalf("hybrid generation activation metadata mismatch %#v", rebuiltMetadata)
		}
	})

	t.Run("native vector capability is explicit", func(t *testing.T) {
		db := setupRAGTestDB(t)
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if _, err := db.Collection("native_vector_probe").InsertOne(ctx, bson.M{"vector": bson.A{1.0, 0.0}}); err != nil {
			t.Fatalf("seed native vector probe: %v", err)
		}
		command := bson.D{
			{Key: "createSearchIndexes", Value: "native_vector_probe"},
			{Key: "indexes", Value: bson.A{bson.M{
				"name": "native_vector_probe",
				"type": "vectorSearch",
				"definition": bson.M{"fields": bson.A{bson.M{
					"type": "vector", "path": "vector", "numDimensions": 2, "similarity": "cosine",
				}}},
			}}},
		}
		if err := db.RunCommand(ctx, command).Err(); err != nil {
			t.Skipf("native MongoDB vector capability unavailable; bounded exact-cosine backend remains active: %v", err)
		}
	})
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
		Content:       "lexical architecture evidence",
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
	if err := projector.ProjectCommittedRun(ctx, "committed-run-1"); err != nil {
		t.Fatalf("project committed run: %v", err)
	}

	metadata, err := projector.Metadata(ctx)
	if err != nil {
		t.Fatalf("read projection metadata: %v", err)
	}
	documentCount, err := db.Collection(rag.DocumentsCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || documentCount != 1 {
		t.Fatalf("expected one committed document immediately after projection, count=%d err=%v", documentCount, err)
	}
	provenanceCount, err := db.Collection(rag.ProvenanceCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || provenanceCount != 1 {
		t.Fatalf("expected one committed provenance link immediately after projection, count=%d err=%v", provenanceCount, err)
	}

	engine := rag.NewEngine(db, rag.Config{PreferredSchemaVersion: "s1"})
	minConfidence := 0.9
	searchRequest := rag.SearchRequest{
		Query:         "lexical",
		TopK:          5,
		Kind:          "claim",
		Sector:        "architecture",
		Status:        "candidate",
		MinConfidence: &minConfidence,
		ContextBytes:  1024,
	}
	assertCommittedSearch := func(label string, expectedCitations int) rag.SearchResponse {
		t.Helper()
		search, searchErr := engine.Search(ctx, searchRequest)
		if searchErr != nil {
			t.Fatalf("%s committed content and exact metadata search: %v", label, searchErr)
		}
		if len(search.Results) != 1 || search.Results[0].StableID != committedNode.StableID {
			t.Fatalf("%s unexpected committed search results %#v", label, search.Results)
		}
		if len(search.Results[0].Citations) != expectedCitations || search.Results[0].CitationStatus != "available" {
			t.Fatalf("%s expected %d resolved citations, got %#v", label, expectedCitations, search.Results[0])
		}
		return search
	}
	assertHiddenNodesAbsent := func(label string) {
		t.Helper()
		search, searchErr := engine.Search(ctx, rag.SearchRequest{
			Query:        "secret",
			TopK:         5,
			ContextBytes: 1024,
		})
		if searchErr != nil {
			t.Fatalf("%s search for uncommitted content: %v", label, searchErr)
		}
		if len(search.Results) != 0 {
			t.Fatalf("%s exposed staging, failed, or unlinked nodes: %#v", label, search.Results)
		}
	}
	assertCommittedSearch("immediate projection", 1)
	assertHiddenNodesAbsent("immediate projection")

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

	documentCount, err = db.Collection(rag.DocumentsCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || documentCount != 1 {
		t.Fatalf("expected one deduplicated document, count=%d err=%v", documentCount, err)
	}
	provenanceCount, err = db.Collection(rag.ProvenanceCollection).CountDocuments(ctx, bson.M{"generation": metadata.ActiveGeneration})
	if err != nil || provenanceCount != 2 {
		t.Fatalf("expected both provenance links, count=%d err=%v", provenanceCount, err)
	}

	search := assertCommittedSearch("concurrent idempotent projection", 2)
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
	search = assertCommittedSearch("generation rebuild", 2)
	if search.Generation != report.Generation {
		t.Fatalf("search used generation %q after rebuild, want %q", search.Generation, report.Generation)
	}
	assertHiddenNodesAbsent("generation rebuild")

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

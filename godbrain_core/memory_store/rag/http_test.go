package rag

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeAPI struct {
	searchRequest SearchRequest
	searchErr     error
	health        HealthResponse
	searchCalls   int
}

type scriptedAPI struct {
	healthResponses []HealthResponse
	searchResponses []SearchResponse
	healthCalls     int
	searchCalls     int
}

func (script *scriptedAPI) Health(context.Context) (HealthResponse, error) {
	if script.healthCalls >= len(script.healthResponses) {
		return HealthResponse{}, errors.New("unexpected health call")
	}
	response := script.healthResponses[script.healthCalls]
	script.healthCalls++
	return response, nil
}

func (script *scriptedAPI) SearchSkills(context.Context, SkillSearchRequest) (SkillSearchResponse, error) {
	return SkillSearchResponse{}, errors.New("unexpected skills call")
}

func (script *scriptedAPI) Search(_ context.Context, _ SearchRequest) (SearchResponse, error) {
	if script.searchCalls >= len(script.searchResponses) {
		return SearchResponse{}, errors.New("unexpected search call")
	}
	response := script.searchResponses[script.searchCalls]
	script.searchCalls++
	return response, nil
}

func (script *scriptedAPI) Graph(context.Context, int) (GraphResponse, error) {
	return GraphResponse{}, errors.New("unexpected graph call")
}

func (script *scriptedAPI) Document(context.Context, string) (DocumentResponse, error) {
	return DocumentResponse{}, errors.New("unexpected document call")
}

func readyHealth(generation string, counts CorpusCounts) HealthResponse {
	return HealthResponse{
		Ready:             true,
		Mongo:             "ok",
		ActiveGeneration:  generation,
		ProjectionVersion: ProjectionVersion,
		ProjectionSchema:  ProjectionSchema,
		IndexerVersion:    IndexerVersion,
		RetrievalMode:     "lexical",
		Semantic: SemanticCapability{
			CorpusLimit:       MaxVectorCorpusDocuments,
			DegradationReason: "embedding_provider_disabled",
		},
		Counts:           counts,
		ReadinessReasons: []string{},
	}
}

func searchRecorder(t *testing.T, api API) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"alpha"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	NewHandler(api).ServeHTTP(response, request)
	return response
}

func (fake *fakeAPI) SearchSkills(_ context.Context, request SkillSearchRequest) (SkillSearchResponse, error) {
	return SkillSearchResponse{Query: request.Query, Skills: []SkillHit{}}, nil
}

func (fake *fakeAPI) Search(_ context.Context, request SearchRequest) (SearchResponse, error) {
	fake.searchCalls++
	fake.searchRequest = request
	return SearchResponse{Query: request.Query, Results: []SearchResult{}}, fake.searchErr
}

func (fake *fakeAPI) Health(context.Context) (HealthResponse, error) {
	if fake.health.ReadinessReasons == nil {
		return HealthResponse{Ready: true}, nil
	}
	return fake.health, nil
}

func (fake *fakeAPI) Graph(_ context.Context, limit int) (GraphResponse, error) {
	if limit > MaxGraphLimit {
		return GraphResponse{}, ErrInvalidGraphLimit
	}
	return GraphResponse{
		Generation:        "gen-1",
		ProjectionVersion: ProjectionVersion,
		ProjectionSchema:  ProjectionSchema,
		Count:             1,
		Links:             []GraphLink{},
		Nodes: []GraphNode{{
			NodeID:   "0123456789abcdef01234567",
			StableID: "claim:auth",
			Kind:     "claim",
			Sector:   "security",
			Status:   "candidate",
			Label:    "Bearer authentication",
		}},
	}, nil
}

func (fake *fakeAPI) Document(_ context.Context, id string) (DocumentResponse, error) {
	if id == "" {
		return DocumentResponse{}, ErrDocumentIDRequired
	}
	if id == "missing" {
		return DocumentResponse{}, ErrDocumentNotFound
	}
	return DocumentResponse{
		NodeID:   "0123456789abcdef01234567",
		StableID: "claim:auth",
		Kind:     "claim",
		Sector:   "security",
		Status:   "candidate",
		Content:  "Bearer authentication protects privileged actions.",
		Label:    "Bearer authentication protects privileged actions.",
	}, nil
}

func TestSearchHandlerStrictJSON(t *testing.T) {
	api := &fakeAPI{health: HealthResponse{Ready: true}}
	handler := NewHandler(api)
	testCases := []struct {
		name string
		body string
	}{
		{name: "unknown field", body: `{"query":"alpha","operator":{"$ne":null}}`},
		{name: "trailing document", body: `{"query":"alpha"}{"query":"beta"}`},
		{name: "trailing token", body: `{"query":"alpha"} true`},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(testCase.body))
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestSearchHandlerBoundsBodyAndContentType(t *testing.T) {
	api := &fakeAPI{health: HealthResponse{Ready: true}}
	handler := NewHandler(api)
	oversized := `{"query":"` + strings.Repeat("x", MaxRequestBodyBytes) + `"}`
	request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(oversized))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected oversized body rejection, got %d", response.Code)
	}

	request = httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"x"}`))
	request.Header.Set("Content-Type", "text/plain")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("expected 415, got %d", response.Code)
	}
}

func TestHealthHandlerSignalsReadiness(t *testing.T) {
	api := &fakeAPI{health: HealthResponse{Ready: false, ReadinessReasons: []string{"projection_lag"}}}
	response := httptest.NewRecorder()
	NewHandler(api).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for unready health, got %d", response.Code)
	}
	var health HealthResponse
	if err := json.NewDecoder(response.Body).Decode(&health); err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	if health.Ready || len(health.ReadinessReasons) != 1 {
		t.Fatalf("unexpected health response %#v", health)
	}
}

func TestSearchHandlerDoesNotExposeInternalErrors(t *testing.T) {
	api := &fakeAPI{searchErr: errors.New("mongodb://user:secret@example.invalid")}
	request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"alpha"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	NewHandler(api).ServeHTTP(response, request)
	if strings.Contains(response.Body.String(), "secret") {
		t.Fatalf("internal error leaked in response: %s", response.Body.String())
	}
}

func TestSearchHandlerFailsClosedWhenCorpusIsUnready(t *testing.T) {
	api := &fakeAPI{health: HealthResponse{
		Ready:            false,
		ReadinessReasons: []string{"projected_node_count_mismatch"},
	}}
	request := httptest.NewRequest(http.MethodPost, "/v1/search", strings.NewReader(`{"query":"alpha"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	NewHandler(api).ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for unready corpus, got %d", response.Code)
	}
	if api.searchCalls != 0 {
		t.Fatal("search ran against an unready corpus")
	}
}

func TestSearchHandlerReturnsOnlyStableSnapshot(t *testing.T) {
	counts := CorpusCounts{CommittedRuns: 1, CommittedNodes: 1, CommittedLinks: 1, ProjectedNodes: 1, ProjectedLinks: 1}
	api := &scriptedAPI{
		healthResponses: []HealthResponse{
			readyHealth("generation-a", counts),
			readyHealth("generation-a", counts),
		},
		searchResponses: []SearchResponse{{
			Query:             "alpha",
			Generation:        "generation-a",
			ProjectionVersion: ProjectionVersion,
			RetrievalMode:     "lexical",
			RequestedMode:     "auto",
			DegradationReason: "embedding_provider_disabled",
			Results:           []SearchResult{},
		}},
	}
	response := searchRecorder(t, api)
	if response.Code != http.StatusOK {
		t.Fatalf("expected stable search success, got %d body=%s", response.Code, response.Body.String())
	}
	if api.healthCalls != 2 || api.searchCalls != 1 {
		t.Fatalf("unexpected calls: health=%d search=%d", api.healthCalls, api.searchCalls)
	}
}

func TestSearchHandlerRejectsPartialProjectionInterleaving(t *testing.T) {
	stableCounts := CorpusCounts{CommittedRuns: 1, CommittedNodes: 1, CommittedLinks: 1, ProjectedNodes: 1, ProjectedLinks: 1}
	partialCounts := CorpusCounts{CommittedRuns: 2, CommittedNodes: 2, CommittedLinks: 2, ProjectedNodes: 2, ProjectedLinks: 1}
	partialHealth := readyHealth("generation-a", partialCounts)
	partialHealth.Ready = false
	partialHealth.ReadinessReasons = []string{"projected_provenance_count_mismatch"}
	api := &scriptedAPI{
		healthResponses: []HealthResponse{
			readyHealth("generation-a", stableCounts),
			partialHealth,
			partialHealth,
		},
		searchResponses: []SearchResponse{{
			Query:             "alpha",
			Generation:        "generation-a",
			ProjectionVersion: ProjectionVersion,
			RetrievalMode:     "lexical",
			RequestedMode:     "auto",
			DegradationReason: "embedding_provider_disabled",
			Results: []SearchResult{{
				StableID:       "partial-node",
				Snippet:        "partial projection must not escape",
				CitationStatus: "missing_provenance",
			}},
		}},
	}
	response := searchRecorder(t, api)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for partial projection, got %d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "partial projection must not escape") {
		t.Fatal("partial search result escaped into the HTTP response")
	}
	if api.searchCalls != 1 {
		t.Fatalf("expected the unready retry to stop before search, got %d searches", api.searchCalls)
	}
}

func TestSearchHandlerRetriesCompletedProjectionWithoutReturningStaleResult(t *testing.T) {
	oldCounts := CorpusCounts{CommittedRuns: 1, CommittedNodes: 1, CommittedLinks: 1, ProjectedNodes: 1, ProjectedLinks: 1}
	newCounts := CorpusCounts{CommittedRuns: 2, CommittedNodes: 2, CommittedLinks: 2, ProjectedNodes: 2, ProjectedLinks: 2}
	api := &scriptedAPI{
		healthResponses: []HealthResponse{
			readyHealth("generation-a", oldCounts),
			readyHealth("generation-a", newCounts),
			readyHealth("generation-a", newCounts),
			readyHealth("generation-a", newCounts),
		},
		searchResponses: []SearchResponse{
			{
				Query: "alpha", Generation: "generation-a", ProjectionVersion: ProjectionVersion,
				RetrievalMode: "lexical", RequestedMode: "auto", DegradationReason: "embedding_provider_disabled",
				Results: []SearchResult{{StableID: "stale-result", Snippet: "discard me"}},
			},
			{
				Query: "alpha", Generation: "generation-a", ProjectionVersion: ProjectionVersion,
				RetrievalMode: "lexical", RequestedMode: "auto", DegradationReason: "embedding_provider_disabled",
				Results: []SearchResult{{StableID: "fresh-result", Snippet: "return me"}},
			},
		},
	}
	response := searchRecorder(t, api)
	if response.Code != http.StatusOK {
		t.Fatalf("expected stable retry success, got %d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "discard me") || !strings.Contains(response.Body.String(), "return me") {
		t.Fatalf("response did not discard the stale attempt: %s", response.Body.String())
	}
	if api.healthCalls != 4 || api.searchCalls != 2 {
		t.Fatalf("unexpected retry calls: health=%d search=%d", api.healthCalls, api.searchCalls)
	}
}

func TestSearchHandlerRejectsRepeatedRebuildActivation(t *testing.T) {
	counts := CorpusCounts{CommittedRuns: 1, CommittedNodes: 1, CommittedLinks: 1, ProjectedNodes: 1, ProjectedLinks: 1}
	api := &scriptedAPI{
		healthResponses: []HealthResponse{
			readyHealth("generation-a", counts),
			readyHealth("generation-b", counts),
			readyHealth("generation-b", counts),
			readyHealth("generation-c", counts),
		},
		searchResponses: []SearchResponse{
			{Query: "alpha", Generation: "generation-a", ProjectionVersion: ProjectionVersion, RetrievalMode: "lexical", RequestedMode: "auto", DegradationReason: "embedding_provider_disabled", Results: []SearchResult{}},
			{Query: "alpha", Generation: "generation-b", ProjectionVersion: ProjectionVersion, RetrievalMode: "lexical", RequestedMode: "auto", DegradationReason: "embedding_provider_disabled", Results: []SearchResult{}},
		},
	}
	response := searchRecorder(t, api)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 after bounded rebuild retries, got %d body=%s", response.Code, response.Body.String())
	}
	if api.healthCalls != 4 || api.searchCalls != maxSearchAttempts {
		t.Fatalf("retry bound changed: health=%d search=%d", api.healthCalls, api.searchCalls)
	}
}

func TestSameSearchSnapshotRejectsMismatchedHybridIdentity(t *testing.T) {
	provider, err := NewDeterministicFakeProvider(32)
	if err != nil {
		t.Fatal(err)
	}
	identity := provider.Identity()
	counts := CorpusCounts{
		CommittedRuns: 1, CommittedNodes: 1, CommittedLinks: 1,
		ProjectedNodes: 1, ProjectedLinks: 1, ProjectedEmbeddings: 1,
	}
	health := readyHealth("generation-a", counts)
	health.RetrievalMode = "hybrid"
	health.Semantic = SemanticCapability{
		Configured: true, Available: true, Identity: &identity,
		CorpusLimit: MaxVectorCorpusDocuments,
	}
	response := SearchResponse{
		Query: "alpha", Generation: "generation-a",
		ProjectionVersion: ProjectionVersion, RetrievalMode: "hybrid",
		RequestedMode: "auto", Embedding: &identity, Results: []SearchResult{},
	}
	if !sameSearchSnapshot(health, health, response) {
		t.Fatal("matching hybrid snapshot was rejected")
	}
	mismatched := identity
	mismatched.ModelRevision = "other"
	response.Embedding = &mismatched
	if sameSearchSnapshot(health, health, response) {
		t.Fatal("hybrid response with mismatched embedding identity was accepted")
	}
}

func TestSearchHandlerReturnsExplicitSemanticUnavailable(t *testing.T) {
	api := &fakeAPI{
		searchErr: ErrSemanticModeUnavailable,
		health: HealthResponse{
			Ready:            true,
			Mongo:            "ok",
			ReadinessReasons: []string{},
		},
	}
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/search",
		strings.NewReader(`{"query":"alpha","retrieval_mode":"hybrid"}`),
	)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	NewHandler(api).ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable ||
		!strings.Contains(response.Body.String(), "semantic_unavailable") {
		t.Fatalf("expected explicit semantic unavailable error, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestGraphHandlerReturnsBoundedNodes(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/graph", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"stable_id":"claim:auth"`) {
		t.Fatalf("graph response missing node: %s", response.Body.String())
	}
}

func TestGraphHandlerRejectsOversizedLimit(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/graph?limit=501", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestGraphHandlerRejectsZeroLimit(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/graph?limit=0", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestGraphHandlerUnready(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/graph", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{
		Ready:            false,
		ReadinessReasons: []string{"projection_lag"},
	}}).ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestDocumentHandlerNotFound(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/document?id=missing", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestDocumentHandlerRequiresID(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/document", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", response.Code, response.Body.String())
	}
}

func TestDocumentHandlerReturnsContent(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/document?id=claim:auth", nil)
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"content":"Bearer authentication protects privileged actions."`) {
		t.Fatalf("document response missing content: %s", response.Body.String())
	}
}

func TestSkillsHandlerReturnsUntrustedHits(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/skills", strings.NewReader(`{"query":"dashboard"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	NewHandler(&fakeAPI{health: HealthResponse{Ready: true, ReadinessReasons: []string{}}}).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"query":"dashboard"`) {
		t.Fatalf("skills response missing query: %s", response.Body.String())
	}
}

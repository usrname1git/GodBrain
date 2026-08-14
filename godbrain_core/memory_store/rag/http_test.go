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

func (script *scriptedAPI) Search(_ context.Context, _ SearchRequest) (SearchResponse, error) {
	if script.searchCalls >= len(script.searchResponses) {
		return SearchResponse{}, errors.New("unexpected search call")
	}
	response := script.searchResponses[script.searchCalls]
	script.searchCalls++
	return response, nil
}

func readyHealth(generation string, counts CorpusCounts) HealthResponse {
	return HealthResponse{
		Ready:             true,
		Mongo:             "ok",
		ActiveGeneration:  generation,
		ProjectionVersion: ProjectionVersion,
		ProjectionSchema:  ProjectionSchema,
		IndexerVersion:    IndexerVersion,
		Counts:            counts,
		ReadinessReasons:  []string{},
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
				Results: []SearchResult{{StableID: "stale-result", Snippet: "discard me"}},
			},
			{
				Query: "alpha", Generation: "generation-a", ProjectionVersion: ProjectionVersion,
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
			{Query: "alpha", Generation: "generation-a", ProjectionVersion: ProjectionVersion, Results: []SearchResult{}},
			{Query: "alpha", Generation: "generation-b", ProjectionVersion: ProjectionVersion, Results: []SearchResult{}},
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

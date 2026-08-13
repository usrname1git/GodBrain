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
}

func (fake *fakeAPI) Search(_ context.Context, request SearchRequest) (SearchResponse, error) {
	fake.searchRequest = request
	return SearchResponse{Query: request.Query, Results: []SearchResult{}}, fake.searchErr
}

func (fake *fakeAPI) Health(context.Context) (HealthResponse, error) {
	return fake.health, nil
}

func TestSearchHandlerStrictJSON(t *testing.T) {
	api := &fakeAPI{}
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
	api := &fakeAPI{}
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

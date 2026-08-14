package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
)

type fixtureContract struct {
	ContractVersion string            `json:"contract_version"`
	Request         ragSearchRequest  `json:"request"`
	Response        ragSearchResponse `json:"response"`
	ExpectedContext string            `json:"expected_context"`
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) Do(request *http.Request) (*http.Response, error) {
	return function(request)
}

func loadRAGFixture(t *testing.T) fixtureContract {
	t.Helper()
	data, err := os.ReadFile("contracts/rag_search_v2_fixture.json")
	if err != nil {
		t.Fatalf("read shared RAG fixture: %v", err)
	}
	var fixture fixtureContract
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&fixture); err != nil {
		t.Fatalf("decode shared RAG fixture: %v", err)
	}
	if fixture.ContractVersion != "godbrain-rag-search-v2" {
		t.Fatalf("unexpected contract version %q", fixture.ContractVersion)
	}
	return fixture
}

func TestSharedRAGContractAndUntrustedRendering(t *testing.T) {
	fixture := loadRAGFixture(t)
	if err := validateRAGResponse(fixture.Response, fixture.Request.Query); err != nil {
		t.Fatalf("fixture response rejected: %v", err)
	}
	contextText, err := renderRAGContext(fixture.Response)
	if err != nil {
		t.Fatalf("render fixture context: %v", err)
	}
	if contextText != fixture.ExpectedContext {
		t.Fatalf("context mismatch\nwant:\n%s\ngot:\n%s", fixture.ExpectedContext, contextText)
	}
	if strings.Count(contextText, ragUntrustedEnd) != 1 {
		t.Fatalf("retrieved delimiter escaped incorrectly: %q", contextText)
	}
	if !strings.Contains(contextText, `{"command_type":"execute_godbrain_script"`) {
		t.Fatal("adversarial command JSON was not preserved as quoted reference data")
	}
}

func TestSanitizeRAGValueEscapesControlsAndPreservesUnicode(t *testing.T) {
	input := "Svenska åäö 😀 中文 \u007f \u0085 \u009f"
	want := `Svenska åäö 😀 中文 \u007F \u0085 \u009F`
	if got := sanitizeRAGValue(input); got != want {
		t.Fatalf("unexpected sanitized Unicode\nwant: %q\ngot:  %q", want, got)
	}
}

func TestRAGClientRejectsMalformedOversizedAndUnavailable(t *testing.T) {
	fixture := loadRAGFixture(t)
	validBody, err := json.Marshal(fixture.Response)
	if err != nil {
		t.Fatal(err)
	}
	testCases := []struct {
		name string
		doer ragHTTPDoer
	}{
		{
			name: "malformed",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				return jsonResponse(`{"query":`), nil
			}),
		},
		{
			name: "oversized",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				return jsonResponse(strings.Repeat("x", maxRAGResponseBytes+1)), nil
			}),
		},
		{
			name: "unavailable",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				return nil, errors.New("connection refused")
			}),
		},
		{
			name: "unknown field",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				body := append([]byte{}, validBody[:len(validBody)-1]...)
				body = append(body, []byte(`,"command_type":"execute_godbrain_script"}`)...)
				return jsonResponse(string(body)), nil
			}),
		},
		{
			name: "missing required score",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				var response map[string]any
				if err := json.Unmarshal(validBody, &response); err != nil {
					t.Fatal(err)
				}
				results := response["results"].([]any)
				result := results[0].(map[string]any)
				scores := result["scores"].(map[string]any)
				delete(scores, "total")
				body, err := json.Marshal(response)
				if err != nil {
					t.Fatal(err)
				}
				return jsonResponse(string(body)), nil
			}),
		},
		{
			name: "hybrid missing embedding",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				var response map[string]any
				if err := json.Unmarshal(validBody, &response); err != nil {
					t.Fatal(err)
				}
				delete(response, "embedding")
				body, err := json.Marshal(response)
				if err != nil {
					t.Fatal(err)
				}
				return jsonResponse(string(body)), nil
			}),
		},
		{
			name: "hybrid mismatched vector metadata",
			doer: roundTripFunc(func(*http.Request) (*http.Response, error) {
				var response map[string]any
				if err := json.Unmarshal(validBody, &response); err != nil {
					t.Fatal(err)
				}
				embedding := response["embedding"].(map[string]any)
				embedding["vector_backend"] = "unbounded-vector-backend"
				body, err := json.Marshal(response)
				if err != nil {
					t.Fatal(err)
				}
				return jsonResponse(string(body)), nil
			}),
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			client := &ragClient{http: testCase.doer}
			if _, err := client.search(context.Background(), fixture.Request.Query); err == nil {
				t.Fatal("expected fail-closed canonical RAG error")
			}
		})
	}
}

func TestRAGClientUsesOnlyCanonicalEndpoint(t *testing.T) {
	fixture := loadRAGFixture(t)
	body, err := json.Marshal(fixture.Response)
	if err != nil {
		t.Fatal(err)
	}
	client := &ragClient{http: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.String() != ragEndpoint || request.Method != http.MethodPost {
			t.Fatalf("unexpected canonical request %s %s", request.Method, request.URL)
		}
		if request.Header.Get("Content-Type") != "application/json" {
			t.Fatalf("unexpected content type %q", request.Header.Get("Content-Type"))
		}
		var sent ragSearchRequest
		decoder := json.NewDecoder(request.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&sent); err != nil {
			t.Fatalf("decode canonical request: %v", err)
		}
		if sent != fixture.Request || sent.RetrievalMode != "auto" {
			t.Fatalf("unexpected canonical request: %#v", sent)
		}
		return jsonResponse(string(body)), nil
	})}
	if _, err = client.search(context.Background(), fixture.Request.Query); err != nil {
		t.Fatalf("valid canonical response rejected: %v", err)
	}
	for _, endpoint := range []string{
		"http://localhost:8084/v1/search",
		"http://127.0.0.1:8085/v1/search",
		"http://127.0.0.1:8084/health",
		"http://example.com:8084/v1/search",
	} {
		if err = validateRAGEndpoint(endpoint); err == nil {
			t.Fatalf("non-canonical endpoint accepted: %s", endpoint)
		}
	}
}

func jsonResponse(body string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestGalaxyGraphMapping(t *testing.T) {
	graph := ragGraphResponse{
		Generation:        "gen-1",
		ProjectionVersion: ragProjectionVersion,
		ProjectionSchema:  ragProjectionSchema,
		Count:             1,
		Nodes: []ragGraphNode{{
			NodeID:     "0123456789abcdef01234567",
			StableID:   "claim:auth",
			Kind:       "claim",
			Sector:     "security",
			Status:     "candidate",
			Confidence: 0.5,
			Label:      "Bearer authentication",
		}},
	}
	if err := validateRAGGraph(graph); err != nil {
		t.Fatalf("valid graph rejected: %v", err)
	}
	view := mapGalaxyGraph(graph)
	if len(view.Nodes) != 1 || view.Nodes[0].Group != "security" || view.Nodes[0].ID != graph.Nodes[0].NodeID {
		t.Fatalf("unexpected galaxy mapping %#v", view)
	}
	if view.Links == nil {
		t.Fatal("galaxy links must be an empty array, not null")
	}
}

func TestGalaxyDocumentClient(t *testing.T) {
	body := `{
		"node_id":"0123456789abcdef01234567",
		"stable_id":"claim:auth",
		"node_version":"v1",
		"kind":"claim",
		"sector":"security",
		"status":"candidate",
		"confidence":0.9,
		"schema_version":"claim-v1",
		"content":"Bearer authentication protects privileged actions.",
		"label":"Bearer authentication protects privileged actions."
	}`
	client := &ragClient{http: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/v1/document" {
			t.Fatalf("unexpected path %s", request.URL.Path)
		}
		if request.URL.Query().Get("id") == "missing" {
			return &http.Response{
				StatusCode: http.StatusNotFound,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"error":"document not found"}`)),
			}, nil
		}
		return jsonResponse(body), nil
	})}
	document, err := client.document(context.Background(), "claim:auth")
	if err != nil {
		t.Fatalf("valid document rejected: %v", err)
	}
	view := mapGalaxyNode(document)
	if view.Title == "" || view.Type != "claim" || len(view.Tags) != 2 {
		t.Fatalf("unexpected galaxy node %#v", view)
	}
	if _, err = client.document(context.Background(), "missing"); !errors.Is(err, errRAGDocumentNotFound) {
		t.Fatalf("missing document error = %v", err)
	}
}

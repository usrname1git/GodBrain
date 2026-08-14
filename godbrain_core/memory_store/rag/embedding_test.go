package rag

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestOpenAICompatibleProviderStrictLoopbackResponse(t *testing.T) {
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/embeddings" ||
			request.Method != http.MethodPost ||
			request.Header.Get("Authorization") != "" {
			t.Fatal("provider request violated the local protocol")
		}
		var payload struct {
			Input          string `json:"input"`
			Model          string `json:"model"`
			EncodingFormat string `json:"encoding_format"`
		}
		decoder := json.NewDecoder(request.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&payload); err != nil {
			t.Fatalf("decode provider request: %v", err)
		}
		if payload.Model != "fixture-model" ||
			payload.EncodingFormat != "float" ||
			payload.Input != "normalized input" {
			t.Fatalf("unexpected request payload %#v", payload)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"object":"list","data":[{"object":"embedding","embedding":[0.25,-0.5,0.75],"index":0}],"model":"fixture-model","usage":{"prompt_tokens":2,"total_tokens":2}}`))
	})
	server := httptest.NewServer(handler)
	defer server.Close()
	provider := newTestOpenAIProvider(t, server.URL+"/v1/embeddings", 3)
	vector, err := provider.Embed(context.Background(), " normalized   input ")
	if err != nil {
		t.Fatalf("Embed failed: %v", err)
	}
	if len(vector) != 3 || vector[0] != 0.25 || vector[1] != -0.5 || vector[2] != 0.75 {
		t.Fatalf("unexpected vector %#v", vector)
	}
}

func TestOpenAICompatibleProviderRejectsInvalidResponses(t *testing.T) {
	testCases := []struct {
		name string
		body string
	}{
		{name: "unknown field", body: `{"object":"list","data":[{"object":"embedding","embedding":[1,2],"index":0,"secret":"x"}],"model":"fixture-model"}`},
		{name: "trailing JSON", body: `{"object":"list","data":[{"object":"embedding","embedding":[1,2],"index":0}],"model":"fixture-model"} true`},
		{name: "wrong model", body: `{"object":"list","data":[{"object":"embedding","embedding":[1,2],"index":0}],"model":"other-model"}`},
		{name: "wrong dimension", body: `{"object":"list","data":[{"object":"embedding","embedding":[1],"index":0}],"model":"fixture-model"}`},
		{name: "zero vector", body: `{"object":"list","data":[{"object":"embedding","embedding":[0,0],"index":0}],"model":"fixture-model"}`},
		{name: "duplicate vectors", body: `{"object":"list","data":[{"object":"embedding","embedding":[1,2],"index":0},{"object":"embedding","embedding":[1,2],"index":1}],"model":"fixture-model"}`},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte(testCase.body))
			}))
			defer server.Close()
			provider := newTestOpenAIProvider(t, server.URL+"/v1/embeddings", 2)
			if _, err := provider.Embed(context.Background(), "input"); !errors.Is(err, ErrEmbeddingResponse) {
				t.Fatalf("expected strict response rejection, got %v", err)
			}
		})
	}
}

func TestOpenAICompatibleProviderRejectsRedirectAndOversizedBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/v1/embeddings" {
			http.Redirect(writer, request, "/other", http.StatusTemporaryRedirect)
			return
		}
	}))
	defer server.Close()
	provider := newTestOpenAIProvider(t, server.URL+"/v1/embeddings", 2)
	if _, err := provider.Embed(context.Background(), "input"); !errors.Is(err, ErrEmbeddingUnavailable) {
		t.Fatalf("redirect must fail closed, got %v", err)
	}
}

func TestOpenAICompatibleProviderRejectsOversizedResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(strings.Repeat("x", MaxEmbeddingResponseBytes+1)))
	}))
	defer server.Close()
	provider := newTestOpenAIProvider(t, server.URL+"/v1/embeddings", 2)
	if _, err := provider.Embed(context.Background(), "input"); !errors.Is(err, ErrEmbeddingResponse) {
		t.Fatalf("oversized response must fail closed, got %v", err)
	}
}

func TestEmbeddingEndpointRequiresCanonicalLiteralLoopback(t *testing.T) {
	invalid := []string{
		"http://localhost:8080/v1/embeddings",
		"http://127.0.0.2:8080/v1/embeddings",
		"https://127.0.0.1:8080/v1/embeddings",
		"http://user@127.0.0.1:8080/v1/embeddings",
		"http://127.0.0.1/v1/embeddings",
		"http://127.0.0.1:8080/v1/embeddings?model=x",
		"http://127.0.0.1:8080/other",
		"http://example.invalid:8080/v1/embeddings",
	}
	for _, endpoint := range invalid {
		t.Run(endpoint, func(t *testing.T) {
			if _, err := NewOpenAICompatibleProvider(OpenAICompatibleConfig{
				Endpoint: endpoint, Model: "model", ModelRevision: "v1",
				ModelHash: strings.Repeat("a", 64), Dimension: 2,
			}); !errors.Is(err, ErrEmbeddingConfiguration) {
				t.Fatalf("unsafe endpoint accepted: %s", endpoint)
			}
		})
	}
}

func TestEmbeddingRuntimeEnvironmentIsDisabledByDefaultAndRejectsPartialConfig(t *testing.T) {
	lookup := func(string) string { return "" }
	runtime, err := embeddingRuntimeFromLookup(lookup)
	if err != nil || runtime.Provider != nil || runtime.Required {
		t.Fatalf("default embedding runtime must be disabled: %#v err=%v", runtime, err)
	}
	values := map[string]string{embeddingEndpointEnv: "http://127.0.0.1:8080/v1/embeddings"}
	_, err = embeddingRuntimeFromLookup(func(key string) string { return values[key] })
	if !errors.Is(err, ErrEmbeddingConfiguration) {
		t.Fatalf("partial embedding configuration must fail closed, got %v", err)
	}
}

func TestDeterministicFakeProviderMatchesSemanticAliases(t *testing.T) {
	provider, err := NewDeterministicFakeProvider(32)
	if err != nil {
		t.Fatal(err)
	}
	left, _ := provider.Embed(context.Background(), "bearer authentication")
	right, _ := provider.Embed(context.Background(), "credential authorization")
	unrelated, _ := provider.Embed(context.Background(), "database storage")
	aliasScore, valid := cosineSimilarity(left, right)
	if !valid {
		t.Fatal("semantic alias vectors are invalid")
	}
	unrelatedScore, valid := cosineSimilarity(left, unrelated)
	if !valid {
		t.Fatal("unrelated vectors are invalid")
	}
	if aliasScore <= unrelatedScore {
		t.Fatalf("deterministic fake did not preserve semantic aliases: alias=%f unrelated=%f", aliasScore, unrelatedScore)
	}
	repeated, _ := provider.Embed(context.Background(), "bearer authentication")
	if strings.TrimSpace(vectorString(left)) != strings.TrimSpace(vectorString(repeated)) {
		t.Fatal("deterministic fake changed output across identical calls")
	}
}

func newTestOpenAIProvider(t *testing.T, endpoint string, dimension int) *OpenAICompatibleProvider {
	t.Helper()
	provider, err := NewOpenAICompatibleProvider(OpenAICompatibleConfig{
		Endpoint:      endpoint,
		Model:         "fixture-model",
		ModelRevision: "revision-1",
		ModelHash:     strings.Repeat("a", 64),
		Dimension:     dimension,
	})
	if err != nil {
		t.Fatalf("create provider: %v", err)
	}
	return provider
}

func vectorString(vector []float32) string {
	var builder strings.Builder
	for _, value := range vector {
		builder.WriteString(strconv.FormatFloat(float64(value), 'g', -1, 32))
		builder.WriteByte(',')
	}
	return builder.String()
}

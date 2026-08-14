package rag

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

const (
	EmbeddingSchemaVersion  = "golden-record-embedding-v1"
	EmbeddingIndexerVersion = "normalized-input-v1"
	VectorBackendVersion    = "mongodb-bounded-exact-cosine-v1"

	MaxEmbeddingDimension     = 4096
	MaxEmbeddingInputBytes    = 16 * 1024
	MaxEmbeddingRequestBytes  = 24 * 1024
	MaxEmbeddingResponseBytes = 1024 * 1024
	MaxVectorCorpusDocuments  = 4096
	EmbeddingRequestTimeout   = 2 * time.Second
)

var (
	ErrEmbeddingDisabled       = errors.New("embedding provider is disabled")
	ErrEmbeddingConfiguration  = errors.New("embedding provider configuration is invalid")
	ErrEmbeddingUnavailable    = errors.New("embedding provider is unavailable")
	ErrEmbeddingResponse       = errors.New("embedding provider returned an invalid response")
	ErrVectorCorpusLimit       = errors.New("vector corpus exceeds the bounded exact-search limit")
	ErrSemanticModeUnavailable = errors.New("semantic retrieval is unavailable")
)

type EmbeddingIdentity struct {
	ProviderKind    string `bson:"provider_kind" json:"provider_kind"`
	ModelIdentifier string `bson:"model_identifier" json:"model_identifier"`
	ModelRevision   string `bson:"model_revision" json:"model_revision"`
	ModelHash       string `bson:"model_hash" json:"model_hash"`
	Dimension       int    `bson:"dimension" json:"dimension"`
	SchemaVersion   string `bson:"embedding_schema" json:"embedding_schema"`
	IndexerVersion  string `bson:"indexer_version" json:"indexer_version"`
	VectorBackend   string `bson:"vector_backend" json:"vector_backend"`
}

func (identity EmbeddingIdentity) Equal(other EmbeddingIdentity) bool {
	return identity == other
}

func (identity EmbeddingIdentity) Validate() error {
	if identity.ProviderKind != "openai-compatible-local" &&
		identity.ProviderKind != "deterministic-test-fake" {
		return ErrEmbeddingConfiguration
	}
	for _, value := range []string{
		identity.ModelIdentifier,
		identity.ModelRevision,
		identity.SchemaVersion,
		identity.IndexerVersion,
		identity.VectorBackend,
	} {
		if !validBoundedIdentity(value, 128) {
			return ErrEmbeddingConfiguration
		}
	}
	if len(identity.ModelHash) != sha256.Size*2 {
		return ErrEmbeddingConfiguration
	}
	if _, err := hex.DecodeString(identity.ModelHash); err != nil ||
		identity.ModelHash != strings.ToLower(identity.ModelHash) {
		return ErrEmbeddingConfiguration
	}
	if identity.Dimension < 1 || identity.Dimension > MaxEmbeddingDimension ||
		identity.SchemaVersion != EmbeddingSchemaVersion ||
		identity.IndexerVersion != EmbeddingIndexerVersion ||
		identity.VectorBackend != VectorBackendVersion {
		return ErrEmbeddingConfiguration
	}
	return nil
}

func validBoundedIdentity(value string, maximum int) bool {
	if value == "" || len(value) > maximum || strings.TrimSpace(value) != value {
		return false
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

type EmbeddingProvider interface {
	Identity() EmbeddingIdentity
	Embed(context.Context, string) ([]float32, error)
	Probe(context.Context) error
}

type EmbeddingRuntime struct {
	Provider EmbeddingProvider
	Required bool
}

type OpenAICompatibleConfig struct {
	Endpoint      string
	Model         string
	ModelRevision string
	ModelHash     string
	Dimension     int
}

type OpenAICompatibleProvider struct {
	endpoint string
	model    string
	identity EmbeddingIdentity
	client   *http.Client
}

func NewOpenAICompatibleProvider(config OpenAICompatibleConfig) (*OpenAICompatibleProvider, error) {
	endpoint, address, err := validateEmbeddingEndpoint(config.Endpoint)
	if err != nil {
		return nil, err
	}
	identity := EmbeddingIdentity{
		ProviderKind:    "openai-compatible-local",
		ModelIdentifier: config.Model,
		ModelRevision:   config.ModelRevision,
		ModelHash:       config.ModelHash,
		Dimension:       config.Dimension,
		SchemaVersion:   EmbeddingSchemaVersion,
		IndexerVersion:  EmbeddingIndexerVersion,
		VectorBackend:   VectorBackendVersion,
	}
	if err = identity.Validate(); err != nil {
		return nil, fmt.Errorf("%w: invalid model identity", ErrEmbeddingConfiguration)
	}
	dialer := &net.Dialer{Timeout: 500 * time.Millisecond, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, target string) (net.Conn, error) {
			if target != address {
				return nil, ErrEmbeddingConfiguration
			}
			return dialer.DialContext(ctx, network, address)
		},
		DisableCompression:    true,
		MaxIdleConns:          2,
		MaxIdleConnsPerHost:   2,
		IdleConnTimeout:       15 * time.Second,
		ResponseHeaderTimeout: time.Second,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   EmbeddingRequestTimeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return errors.New("embedding redirects are disabled")
		},
	}
	return &OpenAICompatibleProvider{
		endpoint: endpoint,
		model:    config.Model,
		identity: identity,
		client:   client,
	}, nil
}

func validateEmbeddingEndpoint(raw string) (string, string, error) {
	parsed, err := url.Parse(raw)
	if err != nil ||
		parsed.Scheme != "http" ||
		parsed.User != nil ||
		parsed.RawQuery != "" ||
		parsed.Fragment != "" ||
		parsed.Path != "/v1/embeddings" {
		return "", "", fmt.Errorf("%w: endpoint must be an exact loopback HTTP /v1/embeddings URL", ErrEmbeddingConfiguration)
	}
	host := parsed.Hostname()
	if host != "127.0.0.1" && host != "::1" {
		return "", "", fmt.Errorf("%w: endpoint host must be 127.0.0.1 or ::1", ErrEmbeddingConfiguration)
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil || port < 1 || port > 65535 {
		return "", "", fmt.Errorf("%w: endpoint requires an explicit valid port", ErrEmbeddingConfiguration)
	}
	address := net.JoinHostPort(host, strconv.Itoa(port))
	expectedHost := address
	if parsed.Host != expectedHost {
		return "", "", fmt.Errorf("%w: endpoint host is not canonical", ErrEmbeddingConfiguration)
	}
	return "http://" + address + "/v1/embeddings", address, nil
}

func (provider *OpenAICompatibleProvider) Identity() EmbeddingIdentity {
	return provider.identity
}

func (provider *OpenAICompatibleProvider) Probe(ctx context.Context) error {
	_, err := provider.Embed(ctx, "godbrain local embedding capability probe")
	return err
}

func (provider *OpenAICompatibleProvider) Embed(ctx context.Context, input string) ([]float32, error) {
	normalized, _ := normalizeEmbeddingInput(input)
	if normalized == "" {
		return nil, fmt.Errorf("%w: empty normalized input", ErrEmbeddingResponse)
	}
	requestBody, err := json.Marshal(struct {
		Input          string `json:"input"`
		Model          string `json:"model"`
		EncodingFormat string `json:"encoding_format"`
	}{
		Input:          normalized,
		Model:          provider.model,
		EncodingFormat: "float",
	})
	if err != nil || len(requestBody) > MaxEmbeddingRequestBytes {
		return nil, ErrEmbeddingConfiguration
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		provider.endpoint,
		bytes.NewReader(requestBody),
	)
	if err != nil {
		return nil, ErrEmbeddingConfiguration
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := provider.client.Do(request)
	if err != nil {
		return nil, ErrEmbeddingUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", ErrEmbeddingUnavailable, response.StatusCode)
	}
	mediaType, _, err := mimeMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, ErrEmbeddingResponse
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, MaxEmbeddingResponseBytes+1))
	if err != nil || len(body) == 0 || len(body) > MaxEmbeddingResponseBytes {
		return nil, ErrEmbeddingResponse
	}
	var payload openAIEmbeddingResponse
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&payload); err != nil {
		return nil, ErrEmbeddingResponse
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, ErrEmbeddingResponse
	}
	if payload.Object != "list" || payload.Model != provider.model ||
		len(payload.Data) != 1 ||
		payload.Data[0].Object != "embedding" ||
		payload.Data[0].Index != 0 ||
		len(payload.Data[0].Embedding) != provider.identity.Dimension {
		return nil, ErrEmbeddingResponse
	}
	vector := make([]float32, len(payload.Data[0].Embedding))
	for index, value := range payload.Data[0].Embedding {
		converted := float32(value)
		if math.IsNaN(value) || math.IsInf(value, 0) ||
			math.IsNaN(float64(converted)) || math.IsInf(float64(converted), 0) {
			return nil, ErrEmbeddingResponse
		}
		vector[index] = converted
	}
	if !validEmbeddingVector(vector, provider.identity.Dimension) {
		return nil, ErrEmbeddingResponse
	}
	return vector, nil
}

func validEmbeddingVector(vector []float32, dimension int) bool {
	if len(vector) != dimension || dimension < 1 || dimension > MaxEmbeddingDimension {
		return false
	}
	var normSquared float64
	for _, value := range vector {
		converted := float64(value)
		if math.IsNaN(converted) || math.IsInf(converted, 0) {
			return false
		}
		normSquared += converted * converted
	}
	return normSquared > 0 && !math.IsNaN(normSquared) && !math.IsInf(normSquared, 0)
}

type openAIEmbeddingResponse struct {
	Object string                `json:"object"`
	Data   []openAIEmbeddingData `json:"data"`
	Model  string                `json:"model"`
	Usage  *openAIEmbeddingUsage `json:"usage,omitempty"`
}

type openAIEmbeddingData struct {
	Object    string    `json:"object"`
	Embedding []float64 `json:"embedding"`
	Index     int       `json:"index"`
}

type openAIEmbeddingUsage struct {
	PromptTokens int `json:"prompt_tokens"`
	TotalTokens  int `json:"total_tokens"`
}

func mimeMediaType(contentType string) (string, map[string]string, error) {
	parts := strings.Split(contentType, ";")
	mediaType := strings.ToLower(strings.TrimSpace(parts[0]))
	if mediaType == "" {
		return "", nil, errors.New("missing media type")
	}
	parameters := make(map[string]string)
	for _, part := range parts[1:] {
		pair := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(pair) != 2 {
			return "", nil, errors.New("invalid media type parameter")
		}
		parameters[strings.ToLower(pair[0])] = strings.Trim(pair[1], `"`)
	}
	return mediaType, parameters, nil
}

func normalizeEmbeddingInput(input string) (string, string) {
	normalized := strings.Join(strings.Fields(norm.NFKC.String(input)), " ")
	if len(normalized) > MaxEmbeddingInputBytes {
		end := MaxEmbeddingInputBytes
		for end > 0 && !utf8.RuneStart(normalized[end]) {
			end--
		}
		normalized = normalized[:end]
	}
	hash := sha256.Sum256([]byte(normalized))
	return normalized, hex.EncodeToString(hash[:])
}

type DeterministicFakeProvider struct {
	identity EmbeddingIdentity
}

func NewDeterministicFakeProvider(dimension int) (*DeterministicFakeProvider, error) {
	identity := EmbeddingIdentity{
		ProviderKind:    "deterministic-test-fake",
		ModelIdentifier: "godbrain-fixture-embedding",
		ModelRevision:   "v1",
		ModelHash:       strings.Repeat("a", sha256.Size*2),
		Dimension:       dimension,
		SchemaVersion:   EmbeddingSchemaVersion,
		IndexerVersion:  EmbeddingIndexerVersion,
		VectorBackend:   VectorBackendVersion,
	}
	if err := identity.Validate(); err != nil {
		return nil, err
	}
	return &DeterministicFakeProvider{identity: identity}, nil
}

func (provider *DeterministicFakeProvider) Identity() EmbeddingIdentity {
	return provider.identity
}

func (provider *DeterministicFakeProvider) Probe(context.Context) error {
	return nil
}

func (provider *DeterministicFakeProvider) Embed(_ context.Context, input string) ([]float32, error) {
	normalized, _ := normalizeEmbeddingInput(input)
	vector := make([]float32, provider.identity.Dimension)
	for _, token := range strings.Fields(strings.ToLower(normalized)) {
		token = semanticFixtureToken(token)
		hash := sha256.Sum256([]byte(token))
		for offset := 0; offset < 8; offset++ {
			index := int(hash[offset]) % len(vector)
			sign := float32(1)
			if hash[offset+8]&1 == 1 {
				sign = -1
			}
			vector[index] += sign * (1 + float32(hash[offset+16])/255)
		}
	}
	var normSquared float64
	for _, value := range vector {
		normSquared += float64(value * value)
	}
	if normSquared == 0 {
		vector[0] = 1
		return vector, nil
	}
	scale := float32(1 / math.Sqrt(normSquared))
	for index := range vector {
		vector[index] *= scale
	}
	return vector, nil
}

func semanticFixtureToken(token string) string {
	switch strings.Trim(token, ".,:;!?()[]{}\"'") {
	case "auth", "authenticate", "authentication", "authorization", "bearer", "credential", "credentials", "token":
		return "concept-security-auth"
	case "restart", "reboot", "recover", "recovery", "resume":
		return "concept-recovery"
	case "database", "mongodb", "store", "storage":
		return "concept-storage"
	case "localhost", "loopback", "127.0.0.1", "::1":
		return "concept-loopback"
	default:
		return token
	}
}

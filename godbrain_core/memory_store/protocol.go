package memorystore

import "time"

// Protocol models the JSON schema exchanged between the C++ Librarian and the Go Memory Store

type Provenance struct {
	SourceID       string  `json:"source_id"`
	SourceType     string  `json:"source_type"`
	SourceHash     string  `json:"source_hash"`
	Language       string  `json:"language"`
	PromptHash     string  `json:"prompt_hash"`
	ModelID        string  `json:"model_id"`
	ModelHash      string  `json:"model_hash"`
	LLMTemperature float64 `json:"llm_temperature"`
}

type Claim struct {
	ClaimID       string   `json:"claim_id"`
	Type          string   `json:"type"`
	Content       string   `json:"content"`
	Confidence    float64  `json:"confidence"`
	EvidenceSpans []string `json:"evidence_spans"` // Byte offset strings "[start:end]"
}

type AlexandriaPayload struct {
	TrustTier       string     `json:"trust_tier"` // Expected: "candidate"
	Provenance      Provenance `json:"provenance"`
	Claims          []Claim    `json:"claims"`
	CoreConcepts    []string   `json:"core_concepts"`
	OpsecCandidates []string   `json:"opsec_candidates"`
}

// DistillationPayload is the master envelope sent on stdin
type DistillationPayload struct {
	ExtractorVersion string            `json:"extractor_version"`
	SchemaVersion    string            `json:"schema_version"`
	Degraded         bool              `json:"degraded"`
	Payload          AlexandriaPayload `json:"payload"`
	RawTranscript    string            `json:"raw_transcript"` // Bypasses C++ size limits
}

// StoreReceipt is the exact JSON structure written back to stdout for the C++ Librarian.
type StoreReceipt struct {
	RunID         string    `json:"run_id"`
	RecordID      string    `json:"record_id"` // Equivalent to IngestionRunID
	Version       string    `json:"version"`
	SchemaVersion string    `json:"schema_version"`
	Status        string    `json:"status"` // "committed", "failed", "idempotent_noop"
	InsertCount   int       `json:"insert_count"`
	UpdateCount   int       `json:"update_count"`
	Timestamp     time.Time `json:"timestamp"`
}

// ErrorEnvelope is the structured error response written to stdout if ingestion fails.
type ErrorEnvelope struct {
	Error   string `json:"error"`
	Details string `json:"details,omitempty"`
}

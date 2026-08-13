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

// DocumentMetadata is optional provenance for local document adapters. Paths are
// deliberately represented by a caller-supplied label and a basename only.
type DocumentMetadata struct {
	SourceLabel      string   `json:"source_label" bson:"source_label"`
	DisplayName      string   `json:"display_name" bson:"display_name"`
	FileSHA256       string   `json:"file_sha256" bson:"file_sha256"`
	ContentSHA256    string   `json:"content_sha256" bson:"content_sha256"`
	ExtractionMethod string   `json:"extraction_method" bson:"extraction_method"`
	Languages        []string `json:"languages" bson:"languages"`
	Backend          string   `json:"backend" bson:"backend"`
	BackendVersion   string   `json:"backend_version" bson:"backend_version"`
	ChunkCount       int      `json:"chunk_count" bson:"chunk_count"`
	OCRConfidence    *float64 `json:"ocr_confidence,omitempty" bson:"ocr_confidence,omitempty"`
}

// SourceChunk is an exact UTF-8 byte range in RawTranscript.
type SourceChunk struct {
	Index      int      `json:"index"`
	Count      int      `json:"count"`
	StartByte  int      `json:"start_byte"`
	EndByte    int      `json:"end_byte"`
	Text       string   `json:"text"`
	Confidence *float64 `json:"confidence,omitempty"`
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
	ExtractorID      string            `json:"extractor_id,omitempty"`
	ExtractorVersion string            `json:"extractor_version"`
	SchemaVersion    string            `json:"schema_version"`
	Degraded         bool              `json:"degraded"`
	Payload          AlexandriaPayload `json:"payload"`
	RawTranscript    string            `json:"raw_transcript"` // Bypasses C++ size limits
	Document         *DocumentMetadata `json:"document,omitempty"`
	Chunks           []SourceChunk     `json:"chunks,omitempty"`
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

package memorystore

import (
	"time"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

// IngestionRun models the state machine: staging -> validated -> committed / failed
// Only committed runs allow their nodes/edges to be queried.
type IngestionRun struct {
	ID               primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	RunID            string             `bson:"run_id" json:"run_id"` // Stable UUID
	Status           string             `bson:"status" json:"status"` // "staging", "validated", "committed", "failed"
	ExtractorID      string             `bson:"extractor_id" json:"extractor_id"`
	ExtractorVer     string             `bson:"extractor_version" json:"extractor_version"`
	SchemaVersion    string             `bson:"schema_version" json:"schema_version"`
	SourceHash       string             `bson:"source_hash" json:"source_hash"`
	PromptHash       string             `bson:"prompt_hash,omitempty" json:"prompt_hash,omitempty"`
	ModelID          string             `bson:"model_id,omitempty" json:"model_id,omitempty"`
	ModelHash        string             `bson:"model_hash,omitempty" json:"model_hash,omitempty"`
	LLMTemperature   float64            `bson:"llm_temperature,omitempty" json:"llm_temperature,omitempty"`
	Active           bool               `bson:"active" json:"active"` // Used for partial unique index (true if not failed)
	LeaseToken       string             `bson:"lease_token,omitempty" json:"lease_token,omitempty"`
	SourceID         primitive.ObjectID `bson:"source_id,omitempty" json:"source_id,omitempty"`
	ExternalSourceID string             `bson:"external_source_id,omitempty" json:"external_source_id,omitempty"`
	Document         *DocumentMetadata  `bson:"document,omitempty" json:"document,omitempty"`
	RetryOf          *string            `bson:"retry_of,omitempty" json:"retry_of,omitempty"`
	ErrorMsg         *string            `bson:"error_msg,omitempty" json:"error_msg,omitempty"`
	CreatedAt        time.Time          `bson:"created_at" json:"created_at"`
	UpdatedAt        time.Time          `bson:"updated_at" json:"updated_at"`
}

// Source represents the immutable raw transcript or document.
type Source struct {
	ID         primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	SourceHash string             `bson:"source_hash" json:"source_hash"`
	SourceType string             `bson:"source_type" json:"source_type"`
	Language   string             `bson:"language" json:"language"`
	Content    string             `bson:"content" json:"content"` // Immutable
	CreatedAt  time.Time          `bson:"created_at" json:"created_at"`
}

// SourceObservation records an instance of raw data being processed, linking external sessions to the immutable source.
type SourceObservation struct {
	ID               primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	SourceHash       string             `bson:"source_hash" json:"source_hash"`
	ExternalSourceID string             `bson:"external_source_id" json:"external_source_id"`
	ExtractorID      string             `bson:"extractor_id" json:"extractor_id"`
	ExtractorVer     string             `bson:"extractor_version" json:"extractor_version"`
	SchemaVersion    string             `bson:"schema_version" json:"schema_version"`
	RunID            string             `bson:"run_id" json:"run_id"`
	Document         *DocumentMetadata  `bson:"document,omitempty" json:"document,omitempty"`
	CreatedAt        time.Time          `bson:"created_at" json:"created_at"`
}

// Chunk represents a segment of a Source, indexed by exact UTF-8 byte offsets.
type Chunk struct {
	ID            primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	SourceHash    string             `bson:"source_hash" json:"source_hash"`
	ExtractorID   string             `bson:"extractor_id" json:"extractor_id"`
	ExtractorVer  string             `bson:"extractor_version" json:"extractor_version"`
	SchemaVersion string             `bson:"schema_version" json:"schema_version"`
	ChunkIndex    int                `bson:"chunk_index" json:"chunk_index"`
	StartByte     int                `bson:"start_byte" json:"start_byte"`
	EndByte       int                `bson:"end_byte" json:"end_byte"`
	Text          string             `bson:"text" json:"text"`
	ChunkCount    int                `bson:"chunk_count" json:"chunk_count"`
	Confidence    *float64           `bson:"confidence,omitempty" json:"confidence,omitempty"`
}

// KnowledgeNode represents Concepts, Claims, and Candidates.
type KnowledgeNode struct {
	ID            primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	StableID      string             `bson:"stable_id" json:"stable_id"` // Hash of normalized content/kind
	Version       string             `bson:"version" json:"version"`     // Versioning for immutability when verified
	Kind          string             `bson:"kind" json:"kind"`           // e.g., "concept", "claim", "opsec_candidate"
	Status        string             `bson:"status" json:"status"`       // candidate, verified, rejected, stale
	Sector        string             `bson:"sector" json:"sector"`       // To scope queries (e.g. "architecture", "security")
	Content       string             `bson:"content" json:"content"`
	Confidence    float64            `bson:"confidence" json:"confidence"`
	EvidenceSpans []string           `bson:"evidence_spans,omitempty" json:"evidence_spans,omitempty"`
	SchemaVersion string             `bson:"schema_version" json:"schema_version"`
	CreatedAt     time.Time          `bson:"created_at" json:"created_at"`
}

// RunNodeLink records which immutable node was observed by an ingestion attempt.
type RunNodeLink struct {
	ID            primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	RunID         string             `bson:"run_id" json:"run_id"`
	NodeID        primitive.ObjectID `bson:"node_id" json:"node_id"`
	StableID      string             `bson:"stable_id" json:"stable_id"`
	NodeVersion   string             `bson:"node_version" json:"node_version"`
	EvidenceSpans []string           `bson:"evidence_spans,omitempty" json:"evidence_spans,omitempty"`
	AttemptToken  string             `bson:"attempt_token" json:"attempt_token"`
	CreatedAt     time.Time          `bson:"created_at" json:"created_at"`
}

// KnowledgeEdge defines typed relations (e.g., node -> node, or evidence -> node).
type KnowledgeEdge struct {
	ID             primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	StableID       string             `bson:"stable_id" json:"stable_id"` // Hash of From+To+Type
	FromID         string             `bson:"from_id" json:"from_id"`
	ToID           string             `bson:"to_id" json:"to_id"`
	EdgeType       string             `bson:"edge_type" json:"edge_type"`
	Confidence     float64            `bson:"confidence" json:"confidence"`
	IngestionRunID string             `bson:"ingestion_run_id" json:"ingestion_run_id"`
	CreatedAt      time.Time          `bson:"created_at" json:"created_at"`
}

// Skill represents a verified capability for Hermes.
// Invariant: Skills can ONLY be derived/created from verified KnowledgeNodes.
type Skill struct {
	ID                  primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	Name                string             `bson:"name" json:"name"`
	Version             string             `bson:"version" json:"version"`
	Content             string             `bson:"content" json:"content"`
	OriginNodeID        string             `bson:"origin_node_id" json:"origin_node_id"` // Reference to the immutable verified node
	OriginVersion       string             `bson:"origin_version" json:"origin_version"` // Node version snapshot
	OriginHash          string             `bson:"origin_hash" json:"origin_hash"`
	SchemaVersion       string             `bson:"schema_version" json:"schema_version"`
	VerificationProfile string             `bson:"verification_profile,omitempty" json:"verification_profile,omitempty"`
	VerificationRunID   string             `bson:"verification_run_id,omitempty" json:"verification_run_id,omitempty"`
	CreatedAt           time.Time          `bson:"created_at" json:"created_at"`
}

// SkillVerificationRun is append-only harness evidence for a candidate skill node.
type SkillVerificationRun struct {
	ID                  primitive.ObjectID `bson:"_id,omitempty" json:"id"`
	RunID               string             `bson:"run_id" json:"run_id"`
	SkillName           string             `bson:"skill_name" json:"skill_name"`
	OriginNodeID        string             `bson:"origin_node_id" json:"origin_node_id"`
	FixtureID           string             `bson:"fixture_id" json:"fixture_id"`
	VerificationProfile string             `bson:"verification_profile" json:"verification_profile"`
	EnvironmentHash     string             `bson:"environment_hash,omitempty" json:"environment_hash,omitempty"`
	Result              string             `bson:"result" json:"result"`
	Checks              map[string]string  `bson:"checks,omitempty" json:"checks,omitempty"`
	ArtifactHash        string             `bson:"artifact_hash,omitempty" json:"artifact_hash,omitempty"`
	LogExcerpt          string             `bson:"log_excerpt,omitempty" json:"log_excerpt,omitempty"`
	Reasoning           string             `bson:"reasoning,omitempty" json:"reasoning,omitempty"`
	CreatedAt           time.Time          `bson:"created_at" json:"created_at"`
}

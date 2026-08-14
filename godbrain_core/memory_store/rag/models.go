package rag

import (
	"time"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

const (
	DocumentsCollection  = "rag_documents"
	ProvenanceCollection = "rag_provenance"
	EmbeddingsCollection = "rag_embeddings"
	MetadataCollection   = "rag_metadata"

	ProjectionVersion = "hybrid-v1"
	ProjectionSchema  = "rag-document-v2"
	IndexerVersion    = "mongodb-text-v1"

	metadataID = "canonical"
)

type RetiredGeneration struct {
	Generation string    `bson:"generation" json:"generation"`
	RetiredAt  time.Time `bson:"retired_at" json:"retired_at"`
}

type Metadata struct {
	ID                 string              `bson:"_id" json:"-"`
	ActiveGeneration   string              `bson:"active_generation" json:"active_generation"`
	BuildingGeneration string              `bson:"building_generation,omitempty" json:"building_generation,omitempty"`
	ProjectionVersion  string              `bson:"projection_version" json:"projection_version"`
	ProjectionSchema   string              `bson:"projection_schema" json:"projection_schema"`
	IndexerVersion     string              `bson:"indexer_version" json:"indexer_version"`
	Embedding          *EmbeddingIdentity  `bson:"embedding,omitempty" json:"embedding,omitempty"`
	BuildingEmbedding  *EmbeddingIdentity  `bson:"building_embedding,omitempty" json:"building_embedding,omitempty"`
	ActiveSince        time.Time           `bson:"active_since" json:"active_since"`
	BuildStartedAt     *time.Time          `bson:"build_started_at,omitempty" json:"build_started_at,omitempty"`
	LastRebuildAt      *time.Time          `bson:"last_rebuild_at,omitempty" json:"last_rebuild_at,omitempty"`
	RetiredGenerations []RetiredGeneration `bson:"retired_generations,omitempty" json:"-"`
	UpdatedAt          time.Time           `bson:"updated_at" json:"updated_at"`
}

type EmbeddingRecord struct {
	ID              primitive.ObjectID `bson:"_id,omitempty" json:"-"`
	Generation      string             `bson:"generation" json:"generation"`
	NodeID          primitive.ObjectID `bson:"node_id" json:"node_id"`
	StableID        string             `bson:"stable_id" json:"stable_id"`
	NodeVersion     string             `bson:"node_version" json:"node_version"`
	ProviderKind    string             `bson:"provider_kind" json:"provider_kind"`
	ModelIdentifier string             `bson:"model_identifier" json:"model_identifier"`
	ModelRevision   string             `bson:"model_revision" json:"model_revision"`
	ModelHash       string             `bson:"model_hash" json:"model_hash"`
	Dimension       int                `bson:"dimension" json:"dimension"`
	InputHash       string             `bson:"input_hash" json:"input_hash"`
	EmbeddingSchema string             `bson:"embedding_schema" json:"embedding_schema"`
	IndexerVersion  string             `bson:"indexer_version" json:"indexer_version"`
	VectorBackend   string             `bson:"vector_backend" json:"vector_backend"`
	Vector          []float32          `bson:"vector" json:"-"`
	ProjectedAt     time.Time          `bson:"projected_at" json:"projected_at"`
}

type Document struct {
	ID                primitive.ObjectID `bson:"_id,omitempty" json:"-"`
	Generation        string             `bson:"generation" json:"generation"`
	NodeID            primitive.ObjectID `bson:"node_id" json:"node_id"`
	StableID          string             `bson:"stable_id" json:"stable_id"`
	NodeVersion       string             `bson:"node_version" json:"node_version"`
	Content           string             `bson:"content" json:"content"`
	Kind              string             `bson:"kind" json:"kind"`
	Sector            string             `bson:"sector" json:"sector"`
	Status            string             `bson:"status" json:"status"`
	Confidence        float64            `bson:"confidence" json:"confidence"`
	SchemaVersion     string             `bson:"schema_version" json:"schema_version"`
	EvidenceSpans     []string           `bson:"evidence_spans,omitempty" json:"evidence_spans,omitempty"`
	NodeCreatedAt     time.Time          `bson:"node_created_at" json:"node_created_at"`
	ProjectionVersion string             `bson:"projection_version" json:"projection_version"`
	ProjectionSchema  string             `bson:"projection_schema" json:"projection_schema"`
	IndexerVersion    string             `bson:"indexer_version" json:"indexer_version"`
	ProjectedAt       time.Time          `bson:"projected_at" json:"projected_at"`
}

type Provenance struct {
	ID               primitive.ObjectID `bson:"_id,omitempty" json:"-"`
	Generation       string             `bson:"generation" json:"generation"`
	NodeID           primitive.ObjectID `bson:"node_id" json:"node_id"`
	StableID         string             `bson:"stable_id" json:"stable_id"`
	NodeVersion      string             `bson:"node_version" json:"node_version"`
	RunID            string             `bson:"run_id" json:"run_id"`
	SourceID         primitive.ObjectID `bson:"source_id,omitempty" json:"source_id,omitempty"`
	SourceHash       string             `bson:"source_hash" json:"source_hash"`
	ExternalSourceID string             `bson:"external_source_id,omitempty" json:"external_source_id,omitempty"`
	ExtractorID      string             `bson:"extractor_id" json:"extractor_id"`
	ExtractorVersion string             `bson:"extractor_version" json:"extractor_version"`
	SchemaVersion    string             `bson:"schema_version" json:"schema_version"`
	EvidenceSpans    []string           `bson:"evidence_spans,omitempty" json:"evidence_spans,omitempty"`
	CommittedAt      time.Time          `bson:"committed_at" json:"committed_at"`
	ProjectedAt      time.Time          `bson:"projected_at" json:"projected_at"`
}

type CorpusCounts struct {
	CommittedRuns       int64 `json:"committed_runs"`
	CommittedNodes      int64 `json:"committed_nodes"`
	CommittedLinks      int64 `json:"committed_links"`
	ProjectedNodes      int64 `json:"projected_nodes"`
	ProjectedLinks      int64 `json:"projected_links"`
	ProjectedEmbeddings int64 `json:"projected_embeddings"`
}

type RebuildReport struct {
	Generation         string       `json:"generation"`
	PreviousGeneration string       `json:"previous_generation"`
	Counts             CorpusCounts `json:"counts"`
	StartedAt          time.Time    `json:"started_at"`
	CompletedAt        time.Time    `json:"completed_at"`
}

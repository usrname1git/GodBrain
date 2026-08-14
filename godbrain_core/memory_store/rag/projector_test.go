package rag

import (
	"testing"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

func TestEmbeddingIdentityFilterIncludesFullIdentity(t *testing.T) {
	nodeID := primitive.NewObjectID()
	identity := EmbeddingIdentity{
		ProviderKind:    "deterministic-test-fake",
		ModelIdentifier: "godbrain-fixture-embedding",
		ModelRevision:   "v1",
		ModelHash:       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Dimension:       64,
		SchemaVersion:   EmbeddingSchemaVersion,
		IndexerVersion:  EmbeddingIndexerVersion,
		VectorBackend:   VectorBackendVersion,
	}
	if err := identity.Validate(); err != nil {
		t.Fatal(err)
	}

	filter := embeddingIdentityFilter("eval-generation-v1", nodeID, identity)
	required := map[string]any{
		"generation":       "eval-generation-v1",
		"node_id":          nodeID,
		"provider_kind":    identity.ProviderKind,
		"model_identifier": identity.ModelIdentifier,
		"model_revision":   identity.ModelRevision,
		"model_hash":       identity.ModelHash,
		"embedding_schema": identity.SchemaVersion,
		"indexer_version":  identity.IndexerVersion,
		"dimension":        identity.Dimension,
		"vector_backend":   identity.VectorBackend,
	}
	if len(filter) != len(required) {
		t.Fatalf("identity filter has %d keys, want %d: %#v", len(filter), len(required), filter)
	}
	for key, want := range required {
		got, ok := filter[key]
		if !ok {
			t.Fatalf("identity filter missing %s", key)
		}
		if got != want {
			t.Fatalf("identity filter %s = %#v, want %#v", key, got, want)
		}
	}
}

package rag

import (
	"fmt"
	"os"
	"strconv"
)

const (
	embeddingEndpointEnv  = "GODBRAIN_EMBEDDING_ENDPOINT"
	embeddingModelEnv     = "GODBRAIN_EMBEDDING_MODEL"
	embeddingRevisionEnv  = "GODBRAIN_EMBEDDING_MODEL_REVISION"
	embeddingHashEnv      = "GODBRAIN_EMBEDDING_MODEL_SHA256"
	embeddingDimensionEnv = "GODBRAIN_EMBEDDING_DIMENSION"
	embeddingRequiredEnv  = "GODBRAIN_RAG_EMBEDDING_REQUIRED"
)

func EmbeddingRuntimeFromEnvironment() (EmbeddingRuntime, error) {
	return embeddingRuntimeFromLookup(os.Getenv)
}

func embeddingRuntimeFromLookup(lookup func(string) string) (EmbeddingRuntime, error) {
	endpoint := lookup(embeddingEndpointEnv)
	model := lookup(embeddingModelEnv)
	revision := lookup(embeddingRevisionEnv)
	modelHash := lookup(embeddingHashEnv)
	dimensionText := lookup(embeddingDimensionEnv)
	requiredText := lookup(embeddingRequiredEnv)

	required := false
	if requiredText != "" {
		var err error
		required, err = strconv.ParseBool(requiredText)
		if err != nil {
			return EmbeddingRuntime{}, fmt.Errorf("%w: %s must be true or false", ErrEmbeddingConfiguration, embeddingRequiredEnv)
		}
	}
	configuredValues := []string{endpoint, model, revision, modelHash, dimensionText}
	configuredCount := 0
	for _, value := range configuredValues {
		if value != "" {
			configuredCount++
		}
	}
	if configuredCount == 0 {
		if required {
			return EmbeddingRuntime{}, fmt.Errorf("%w: required provider is not configured", ErrEmbeddingConfiguration)
		}
		return EmbeddingRuntime{}, nil
	}
	if configuredCount != len(configuredValues) {
		return EmbeddingRuntime{}, fmt.Errorf("%w: all embedding identity variables must be set together", ErrEmbeddingConfiguration)
	}
	dimension, err := strconv.Atoi(dimensionText)
	if err != nil {
		return EmbeddingRuntime{}, fmt.Errorf("%w: invalid embedding dimension", ErrEmbeddingConfiguration)
	}
	provider, err := NewOpenAICompatibleProvider(OpenAICompatibleConfig{
		Endpoint:      endpoint,
		Model:         model,
		ModelRevision: revision,
		ModelHash:     modelHash,
		Dimension:     dimension,
	})
	if err != nil {
		return EmbeddingRuntime{}, err
	}
	return EmbeddingRuntime{Provider: provider, Required: required}, nil
}

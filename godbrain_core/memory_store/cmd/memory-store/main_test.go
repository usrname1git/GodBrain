package main

import (
	"bytes"
	"errors"
	"testing"

	memorystore "godbrain_core/memory_store"
)

func TestReadInputRejectsMongoOversizePayload(t *testing.T) {
	input := bytes.Repeat([]byte{'x'}, maxInputBytes+1)
	if _, err := readInput(bytes.NewReader(input)); !errors.Is(err, errInputTooLarge) {
		t.Fatalf("expected errInputTooLarge, got %v", err)
	}
}

func TestPayloadNodeCountIncludesEveryNodeKind(t *testing.T) {
	payload := memorystore.DistillationPayload{
		Payload: memorystore.AlexandriaPayload{
			Claims:          make([]memorystore.Claim, 2),
			CoreConcepts:    []string{"one", "two", "three"},
			OpsecCandidates: []string{"candidate"},
		},
	}
	if count := payloadNodeCount(payload); count != 6 {
		t.Fatalf("expected 6 nodes, got %d", count)
	}
}

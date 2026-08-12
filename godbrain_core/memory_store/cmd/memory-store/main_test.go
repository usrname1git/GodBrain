package main

import (
	"bytes"
	"errors"
	"testing"
)

func TestReadInputRejectsMongoOversizePayload(t *testing.T) {
	input := bytes.Repeat([]byte{'x'}, maxInputBytes+1)
	if _, err := readInput(bytes.NewReader(input)); !errors.Is(err, errInputTooLarge) {
		t.Fatalf("expected errInputTooLarge, got %v", err)
	}
}

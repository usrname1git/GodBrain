package rag

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestDecodeDeskEvalFile(t *testing.T) {
	data, err := os.ReadFile("testdata/desk_eval_queries.json")
	if err != nil {
		t.Fatal(err)
	}
	file, err := DecodeDeskEvalFile(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("decode desk eval: %v", err)
	}
	if file.Version != DeskEvalVersion || len(file.Queries) < 8 {
		t.Fatalf("unexpected desk eval: %+v", file)
	}
	if got := MatchDeskNeedles("Heal Watch never kills", []string{"Heal", "missing"}); len(got) != 1 || got[0] != "Heal" {
		t.Fatalf("needles=%v", got)
	}
}

func TestDeskEvalFileRejectsUnknownFields(t *testing.T) {
	data, err := os.ReadFile("testdata/desk_eval_queries.json")
	if err != nil {
		t.Fatal(err)
	}
	mutated := append([]byte(`{"extra":true,`), data[1:]...)
	_, err = DecodeDeskEvalFile(bytes.NewReader(mutated))
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("want unknown-field error, got %v", err)
	}
}

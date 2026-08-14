package rag

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestDeterministicHybridEvaluationThresholdsAndRepeatability(t *testing.T) {
	data, err := os.ReadFile("testdata/hybrid_eval_corpus.json")
	if err != nil {
		t.Fatal(err)
	}
	corpus, err := DecodeEvalCorpus(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("decode evaluation corpus: %v", err)
	}
	provider, err := NewDeterministicFakeProvider(64)
	if err != nil {
		t.Fatal(err)
	}
	first, err := EvaluateCorpus(context.Background(), corpus, provider, false)
	if err != nil {
		t.Fatalf("evaluate corpus: %v", err)
	}
	if err = ValidateEvalThresholds(first); err != nil {
		t.Fatalf("evaluation regression: %v; report=%#v", err, first)
	}
	second, err := EvaluateCorpus(context.Background(), corpus, provider, false)
	if err != nil {
		t.Fatal(err)
	}
	firstJSON, err := RenderEvalReport(first)
	if err != nil {
		t.Fatal(err)
	}
	secondJSON, err := RenderEvalReport(second)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(firstJSON, secondJSON) {
		t.Fatal("deterministic evaluation report changed byte-for-byte")
	}
}

func TestEvaluationCorpusStrictlyRejectsUnknownFields(t *testing.T) {
	data, err := os.ReadFile("testdata/hybrid_eval_corpus.json")
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]json.RawMessage
	if err = json.Unmarshal(data, &payload); err != nil {
		t.Fatal(err)
	}
	payload["unexpected"] = json.RawMessage("true")
	mutated, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	_, err = DecodeEvalCorpus(bytes.NewReader(mutated))
	if err == nil {
		t.Fatal("unknown corpus field was accepted")
	}
	if !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("want unknown-field error, got %v", err)
	}
}

func TestEvaluationDetectsBoundaryLeakage(t *testing.T) {
	data, err := os.ReadFile("testdata/hybrid_eval_corpus.json")
	if err != nil {
		t.Fatal(err)
	}
	corpus, err := DecodeEvalCorpus(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	for index := range corpus.Documents {
		if corpus.Documents[index].ID == "hidden-staging" {
			corpus.Documents[index].Committed = true
		}
	}
	provider, err := NewDeterministicFakeProvider(64)
	if err != nil {
		t.Fatal(err)
	}
	report, err := EvaluateCorpus(context.Background(), corpus, provider, false)
	if err != nil {
		t.Fatal(err)
	}
	if report.HiddenRecordLeakage == 0 {
		t.Fatal("evaluation did not detect an uncommitted-record visibility regression")
	}
}

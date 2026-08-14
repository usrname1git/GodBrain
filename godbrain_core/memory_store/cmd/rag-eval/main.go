package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"

	"godbrain_core/memory_store/rag"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "RAG evaluation failed:", err)
		os.Exit(1)
	}
}

func run() error {
	corpusPath := flag.String(
		"corpus",
		"rag/testdata/hybrid_eval_corpus.json",
		"path to the synthetic deterministic evaluation corpus",
	)
	measureRuntime := flag.Bool(
		"measure-latency",
		false,
		"include nondeterministic wall-clock latency separately from deterministic metrics",
	)
	flag.Parse()
	data, err := os.ReadFile(*corpusPath)
	if err != nil {
		return err
	}
	corpus, err := rag.DecodeEvalCorpus(bytes.NewReader(data))
	if err != nil {
		return err
	}
	provider, err := rag.NewDeterministicFakeProvider(64)
	if err != nil {
		return err
	}
	report, err := rag.EvaluateCorpus(
		context.Background(),
		corpus,
		provider,
		*measureRuntime,
	)
	if err != nil {
		return err
	}
	if err = rag.ValidateEvalThresholds(report); err != nil {
		return err
	}
	rendered, err := rag.RenderEvalReport(report)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(rendered)
	return err
}

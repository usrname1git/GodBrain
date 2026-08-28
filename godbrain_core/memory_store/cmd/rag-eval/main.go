package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

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
	deskPath := flag.String(
		"desk",
		"rag/testdata/desk_eval_queries.json",
		"path to the opt-in live desk query file",
	)
	endpoint := flag.String(
		"endpoint",
		"http://127.0.0.1:8084",
		"loopback RAG origin for -live",
	)
	live := flag.Bool(
		"live",
		false,
		"query the running RAG service with desk-shaped needles (opt-in, not a quality claim)",
	)
	strict := flag.Bool(
		"strict",
		false,
		"with -live, fail if any desk query misses its needles",
	)
	measureRuntime := flag.Bool(
		"measure-latency",
		false,
		"include nondeterministic wall-clock latency separately from deterministic metrics",
	)
	flag.Parse()
	if *live {
		return runLiveDesk(*deskPath, *endpoint, *strict)
	}
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

func runLiveDesk(path, origin string, strict bool) error {
	origin = strings.TrimRight(strings.TrimSpace(origin), "/")
	if origin != "http://127.0.0.1:8084" && origin != "http://localhost:8084" {
		return fmt.Errorf("live eval is loopback-only, got %q", origin)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	file, err := rag.DecodeDeskEvalFile(bytes.NewReader(data))
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 8 * time.Second}
	ready, err := liveReady(client, origin+"/health")
	if err != nil {
		return err
	}
	if !ready {
		return fmt.Errorf("RAG %s is unready", origin)
	}
	report := rag.DeskEvalReport{
		Version:    file.Version,
		Endpoint:   origin + "/v1/search",
		Ready:      true,
		QueryCount: len(file.Queries),
		Queries:    make([]rag.DeskEvalHit, 0, len(file.Queries)),
	}
	verified := "verified"
	for _, query := range file.Queries {
		hit := rag.DeskEvalHit{ID: query.ID, Query: query.Query}
		body, err := json.Marshal(rag.SearchRequest{
			Query:  query.Query,
			TopK:   file.TopK,
			Sector: query.Sector,
			Status: verified,
		})
		if err != nil {
			return err
		}
		resp, err := client.Post(origin+"/v1/search", "application/json", bytes.NewReader(body))
		if err != nil {
			hit.Error = err.Error()
			report.Misses++
			report.Queries = append(report.Queries, hit)
			continue
		}
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		_ = resp.Body.Close()
		if readErr != nil {
			hit.Error = readErr.Error()
			report.Misses++
			report.Queries = append(report.Queries, hit)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			hit.Error = fmt.Sprintf("status %d", resp.StatusCode)
			report.Misses++
			report.Queries = append(report.Queries, hit)
			continue
		}
		var search rag.SearchResponse
		if err = json.Unmarshal(raw, &search); err != nil {
			hit.Error = "invalid search response"
			report.Misses++
			report.Queries = append(report.Queries, hit)
			continue
		}
		hit.Count = len(search.Results)
		if hit.Count == 0 {
			report.Empty++
			report.Misses++
			report.Queries = append(report.Queries, hit)
			continue
		}
		var combined strings.Builder
		for _, result := range search.Results {
			combined.WriteString(result.Snippet)
			combined.WriteByte('\n')
			combined.WriteString(result.StableID)
			combined.WriteByte('\n')
		}
		hit.Needles = rag.MatchDeskNeedles(combined.String(), query.Needles)
		hit.Hit = len(hit.Needles) > 0
		if len(search.Results) > 0 {
			snippet := search.Results[0].Snippet
			if len(snippet) > 160 {
				snippet = snippet[:160]
			}
			hit.Snippet = snippet
		}
		if hit.Hit {
			report.Hits++
		} else {
			report.Misses++
		}
		report.Queries = append(report.Queries, hit)
	}
	rendered, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	if _, err = os.Stdout.Write(append(rendered, '\n')); err != nil {
		return err
	}
	if report.Hits == 0 {
		return fmt.Errorf("live desk eval: RAG ready but zero needle hits")
	}
	if strict && report.Misses > 0 {
		return fmt.Errorf("live desk eval: %d miss(es) under -strict", report.Misses)
	}
	return nil
}

func liveReady(client *http.Client, url string) (bool, error) {
	resp, err := client.Get(url)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024))
	if err != nil {
		return false, err
	}
	if resp.StatusCode != http.StatusOK {
		return false, nil
	}
	var health rag.HealthResponse
	if err = json.Unmarshal(raw, &health); err != nil {
		return false, fmt.Errorf("invalid health response")
	}
	return health.Ready, nil
}

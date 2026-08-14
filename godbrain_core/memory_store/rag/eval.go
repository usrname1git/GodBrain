package rag

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
	"time"
)

const EvalCorpusVersion = "godbrain-hybrid-eval-v1"

type EvalCorpus struct {
	Version          string         `json:"version"`
	ActiveGeneration string         `json:"active_generation"`
	TopK             int            `json:"top_k"`
	Documents        []EvalDocument `json:"documents"`
	Queries          []EvalQuery    `json:"queries"`
}

type EvalDocument struct {
	ID              string  `json:"id"`
	StableID        string  `json:"stable_id"`
	Version         string  `json:"version"`
	Content         string  `json:"content"`
	Kind            string  `json:"kind"`
	Sector          string  `json:"sector"`
	Status          string  `json:"status"`
	Confidence      float64 `json:"confidence"`
	SourceID        string  `json:"source_id"`
	Generation      string  `json:"generation"`
	Committed       bool    `json:"committed"`
	CitationState   string  `json:"citation_state"`
	ExpectedVisible bool    `json:"expected_visible"`
	PromptInjection bool    `json:"prompt_injection,omitempty"`
}

type EvalQuery struct {
	ID              string   `json:"id"`
	Text            string   `json:"text"`
	Kind            string   `json:"kind,omitempty"`
	Sector          string   `json:"sector,omitempty"`
	Status          string   `json:"status,omitempty"`
	RelevantIDs     []string `json:"relevant_ids"`
	ExpectNoResults bool     `json:"expect_no_results,omitempty"`
}

type EvalQueryResult struct {
	ID             string   `json:"id"`
	ReturnedIDs    []string `json:"returned_ids"`
	RecallAtK      float64  `json:"recall_at_k"`
	ReciprocalRank float64  `json:"reciprocal_rank"`
	NDCGAtK        float64  `json:"ndcg_at_k"`
	WorkUnits      int      `json:"work_units"`
}

type EvalLatencyDistribution struct {
	Unit       string `json:"unit"`
	P50        int    `json:"p50"`
	P95        int    `json:"p95"`
	Maximum    int    `json:"maximum"`
	Budget     int    `json:"budget"`
	BudgetPass bool   `json:"budget_pass"`
}

type EvalRuntimeLatency struct {
	P50Microseconds    int64 `json:"p50_microseconds"`
	P95Microseconds    int64 `json:"p95_microseconds"`
	MaxMicroseconds    int64 `json:"max_microseconds"`
	BudgetMicroseconds int64 `json:"budget_microseconds"`
	BudgetPass         bool  `json:"budget_pass"`
}

type EvalReport struct {
	CorpusVersion         string                  `json:"corpus_version"`
	ProviderKind          string                  `json:"provider_kind"`
	ModelIdentifier       string                  `json:"model_identifier"`
	QueryCount            int                     `json:"query_count"`
	RecallAtK             float64                 `json:"recall_at_k"`
	MRR                   float64                 `json:"mrr"`
	NDCGAtK               float64                 `json:"ndcg_at_k"`
	CitationCorrectness   float64                 `json:"citation_correctness"`
	CitationCoverage      float64                 `json:"citation_coverage"`
	HiddenRecordLeakage   int                     `json:"hidden_record_leakage"`
	GenerationCorrectness float64                 `json:"generation_correctness"`
	NoResultCorrectness   float64                 `json:"no_result_correctness"`
	PromptInjectionAsData bool                    `json:"prompt_injection_as_data"`
	DeterministicLatency  EvalLatencyDistribution `json:"deterministic_latency"`
	RuntimeLatency        *EvalRuntimeLatency     `json:"runtime_latency,omitempty"`
	Queries               []EvalQueryResult       `json:"queries"`
}

type evalCandidate struct {
	document     EvalDocument
	lexicalScore float64
	vectorScore  float64
	lexicalRank  int
	semanticRank int
	fusionScore  float64
}

func DecodeEvalCorpus(reader io.Reader) (EvalCorpus, error) {
	var corpus EvalCorpus
	decoder := json.NewDecoder(io.LimitReader(reader, 2*1024*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&corpus); err != nil {
		return corpus, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return corpus, errors.New("evaluation corpus must contain exactly one JSON document")
	}
	if corpus.Version != EvalCorpusVersion ||
		corpus.ActiveGeneration == "" ||
		corpus.TopK < 1 ||
		corpus.TopK > MaxTopK ||
		len(corpus.Documents) == 0 ||
		len(corpus.Documents) > MaxVectorCorpusDocuments ||
		len(corpus.Queries) == 0 {
		return corpus, errors.New("evaluation corpus metadata is invalid")
	}
	var uncommitted, stale, missingCitation, wrongCitation bool
	for _, document := range corpus.Documents {
		if document.ID == "" || document.StableID == "" || document.Version == "" ||
			document.Content == "" || document.SourceID == "" || document.Generation == "" ||
			math.IsNaN(document.Confidence) || math.IsInf(document.Confidence, 0) ||
			document.Confidence < 0 || document.Confidence > 1 {
			return corpus, errors.New("evaluation document is invalid")
		}
		switch document.CitationState {
		case "valid":
		case "missing":
			missingCitation = true
		case "wrong":
			wrongCitation = true
		default:
			return corpus, errors.New("evaluation document citation_state is invalid")
		}
		uncommitted = uncommitted || !document.Committed
		stale = stale || document.Generation != corpus.ActiveGeneration
	}
	if !uncommitted || !stale || !missingCitation || !wrongCitation {
		return corpus, errors.New("evaluation corpus is missing required boundary probes")
	}
	return corpus, nil
}

func EvaluateCorpus(
	ctx context.Context,
	corpus EvalCorpus,
	provider EmbeddingProvider,
	measureRuntime bool,
) (EvalReport, error) {
	if provider == nil || provider.Identity().ProviderKind != "deterministic-test-fake" {
		return EvalReport{}, errors.New("offline evaluation requires the deterministic test provider")
	}
	documentVectors := make(map[string][]float32, len(corpus.Documents))
	hiddenIDs := make(map[string]struct{})
	for _, document := range corpus.Documents {
		if !document.ExpectedVisible {
			hiddenIDs[document.ID] = struct{}{}
		}
		vector, err := provider.Embed(ctx, document.Content)
		if err != nil {
			return EvalReport{}, err
		}
		documentVectors[document.ID] = vector
	}

	report := EvalReport{
		CorpusVersion:   corpus.Version,
		ProviderKind:    provider.Identity().ProviderKind,
		ModelIdentifier: provider.Identity().ModelIdentifier,
		QueryCount:      len(corpus.Queries),
		Queries:         make([]EvalQueryResult, 0, len(corpus.Queries)),
	}
	workUnits := make([]int, 0, len(corpus.Queries))
	runtimeMicros := make([]int64, 0, len(corpus.Queries))
	var recallTotal, reciprocalTotal, ndcgTotal float64
	var returnedCount, validCitationCount, citedResultCount int
	var noResultTotal, noResultCorrect int
	generationValid := 0
	promptInjectionSeen := false

	for _, query := range corpus.Queries {
		startedAt := time.Now()
		results, work, err := evaluateQuery(ctx, corpus, query, corpus.Documents, documentVectors, provider)
		if err != nil {
			return EvalReport{}, err
		}
		if measureRuntime {
			runtimeMicros = append(runtimeMicros, time.Since(startedAt).Microseconds())
		}
		workUnits = append(workUnits, work)
		metrics := evaluateQueryMetrics(query, results, corpus.TopK)
		recallTotal += metrics.RecallAtK
		reciprocalTotal += metrics.ReciprocalRank
		ndcgTotal += metrics.NDCGAtK
		metrics.WorkUnits = work
		report.Queries = append(report.Queries, metrics)
		if query.ExpectNoResults {
			noResultTotal++
			if len(results) == 0 {
				noResultCorrect++
			}
		}
		for _, result := range results {
			returnedCount++
			if result.CitationState == "valid" {
				validCitationCount++
				citedResultCount++
			}
			if result.Generation == corpus.ActiveGeneration {
				generationValid++
			}
			if _, hidden := hiddenIDs[result.ID]; hidden {
				report.HiddenRecordLeakage++
			}
			if result.PromptInjection {
				promptInjectionSeen = true
			}
		}
	}
	queryCount := float64(len(corpus.Queries))
	report.RecallAtK = recallTotal / queryCount
	report.MRR = reciprocalTotal / queryCount
	report.NDCGAtK = ndcgTotal / queryCount
	if returnedCount > 0 {
		report.CitationCorrectness = float64(validCitationCount) / float64(returnedCount)
		report.CitationCoverage = float64(citedResultCount) / float64(returnedCount)
		report.GenerationCorrectness = float64(generationValid) / float64(returnedCount)
	} else {
		report.CitationCorrectness = 1
		report.CitationCoverage = 1
		report.GenerationCorrectness = 1
	}
	if noResultTotal > 0 {
		report.NoResultCorrectness = float64(noResultCorrect) / float64(noResultTotal)
	} else {
		report.NoResultCorrectness = 1
	}
	report.PromptInjectionAsData = promptInjectionSeen
	report.DeterministicLatency = workLatency(workUnits, MaxVectorCorpusDocuments*2)
	if measureRuntime {
		report.RuntimeLatency = runtimeLatency(runtimeMicros, 50_000)
	}
	return report, nil
}

func evaluateQuery(
	ctx context.Context,
	corpus EvalCorpus,
	query EvalQuery,
	documents []EvalDocument,
	documentVectors map[string][]float32,
	provider EmbeddingProvider,
) ([]EvalDocument, int, error) {
	normalized, queryTokens, err := NormalizeQuery(query.Text)
	if err != nil {
		return nil, 0, err
	}
	queryVector, err := provider.Embed(ctx, normalized)
	if err != nil {
		return nil, 0, err
	}
	candidates := make([]evalCandidate, 0, len(documents))
	for _, document := range documents {
		if query.Kind != "" && document.Kind != query.Kind ||
			query.Sector != "" && document.Sector != query.Sector ||
			query.Status != "" && document.Status != query.Status {
			continue
		}
		if !document.Committed || document.Generation != corpus.ActiveGeneration {
			continue
		}
		_, documentTokens, tokenErr := NormalizeQuery(document.Content)
		if tokenErr != nil {
			return nil, 0, tokenErr
		}
		lexical := tokenOverlap(queryTokens, documentTokens)
		vector, valid := cosineSimilarity(queryVector, documentVectors[document.ID])
		if !valid {
			return nil, 0, ErrEmbeddingResponse
		}
		candidates = append(candidates, evalCandidate{
			document: document, lexicalScore: lexical, vectorScore: vector,
		})
	}
	lexical := append([]evalCandidate(nil), candidates...)
	sort.Slice(lexical, func(i, j int) bool {
		if lexical[i].lexicalScore != lexical[j].lexicalScore {
			return lexical[i].lexicalScore > lexical[j].lexicalScore
		}
		return lexical[i].document.ID < lexical[j].document.ID
	})
	lexicalRanks := make(map[string]int)
	rank := 0
	for _, candidate := range lexical {
		if candidate.lexicalScore <= 0 {
			continue
		}
		rank++
		lexicalRanks[candidate.document.ID] = rank
	}
	semantic := append([]evalCandidate(nil), candidates...)
	sort.Slice(semantic, func(i, j int) bool {
		if semantic[i].vectorScore != semantic[j].vectorScore {
			return semantic[i].vectorScore > semantic[j].vectorScore
		}
		return semantic[i].document.ID < semantic[j].document.ID
	})
	semanticRanks := make(map[string]int)
	rank = 0
	for _, candidate := range semantic {
		if candidate.vectorScore < MinSemanticSimilarity {
			continue
		}
		rank++
		semanticRanks[candidate.document.ID] = rank
	}
	fused := candidates[:0]
	for _, candidate := range candidates {
		candidate.lexicalRank = lexicalRanks[candidate.document.ID]
		candidate.semanticRank = semanticRanks[candidate.document.ID]
		if candidate.lexicalRank == 0 && candidate.semanticRank == 0 {
			continue
		}
		candidate.fusionScore = reciprocalRank(candidate.lexicalRank) +
			reciprocalRank(candidate.semanticRank) +
			evalTrust(candidate.document.Status)*0.001 +
			clamp01(candidate.document.Confidence)*0.001
		fused = append(fused, candidate)
	}
	sort.Slice(fused, func(i, j int) bool {
		if fused[i].fusionScore != fused[j].fusionScore {
			return fused[i].fusionScore > fused[j].fusionScore
		}
		if fused[i].document.StableID != fused[j].document.StableID {
			return fused[i].document.StableID < fused[j].document.StableID
		}
		return fused[i].document.ID < fused[j].document.ID
	})
	selected := make([]EvalDocument, 0, corpus.TopK)
	seenStable := make(map[string]struct{})
	sourceUses := make(map[string]int)
	for _, candidate := range fused {
		if len(selected) >= corpus.TopK {
			break
		}
		if _, duplicate := seenStable[candidate.document.StableID]; duplicate {
			continue
		}
		if sourceUses[candidate.document.SourceID] >= 2 {
			continue
		}
		seenStable[candidate.document.StableID] = struct{}{}
		sourceUses[candidate.document.SourceID]++
		selected = append(selected, candidate.document)
	}
	results := make([]EvalDocument, 0, len(selected))
	for _, document := range selected {
		if document.CitationState == "valid" {
			results = append(results, document)
		}
	}
	return results, len(documents) * 2, nil
}

func tokenOverlap(left, right []string) float64 {
	rightSet := make(map[string]struct{}, len(right))
	for _, token := range right {
		rightSet[token] = struct{}{}
	}
	var matches int
	for _, token := range left {
		if _, exists := rightSet[token]; exists {
			matches++
		}
	}
	return float64(matches)
}

func evalTrust(status string) float64 {
	switch status {
	case "verified":
		return 1
	case "candidate":
		return 0.25
	case "rejected":
		return -1
	default:
		return 0
	}
}

func evaluateQueryMetrics(query EvalQuery, results []EvalDocument, topK int) EvalQueryResult {
	metrics := EvalQueryResult{ID: query.ID, ReturnedIDs: make([]string, 0, len(results))}
	relevant := make(map[string]struct{}, len(query.RelevantIDs))
	for _, id := range query.RelevantIDs {
		relevant[id] = struct{}{}
	}
	var hits int
	var dcg float64
	for index, result := range results {
		metrics.ReturnedIDs = append(metrics.ReturnedIDs, result.ID)
		if _, match := relevant[result.ID]; !match {
			continue
		}
		hits++
		if metrics.ReciprocalRank == 0 {
			metrics.ReciprocalRank = 1 / float64(index+1)
		}
		dcg += 1 / math.Log2(float64(index)+2)
	}
	if len(relevant) == 0 {
		if len(results) == 0 {
			metrics.RecallAtK = 1
			metrics.ReciprocalRank = 1
			metrics.NDCGAtK = 1
		}
		return metrics
	}
	metrics.RecallAtK = float64(hits) / float64(len(relevant))
	idealCount := len(relevant)
	if idealCount > topK {
		idealCount = topK
	}
	var ideal float64
	for index := 0; index < idealCount; index++ {
		ideal += 1 / math.Log2(float64(index)+2)
	}
	if ideal > 0 {
		metrics.NDCGAtK = dcg / ideal
	}
	return metrics
}

func workLatency(values []int, budget int) EvalLatencyDistribution {
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	maximum := sorted[len(sorted)-1]
	return EvalLatencyDistribution{
		Unit:       "bounded_document_comparisons",
		P50:        integerPercentile(sorted, 50),
		P95:        integerPercentile(sorted, 95),
		Maximum:    maximum,
		Budget:     budget,
		BudgetPass: maximum <= budget,
	}
}

func runtimeLatency(values []int64, budget int64) *EvalRuntimeLatency {
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	maximum := sorted[len(sorted)-1]
	return &EvalRuntimeLatency{
		P50Microseconds:    integer64Percentile(sorted, 50),
		P95Microseconds:    integer64Percentile(sorted, 95),
		MaxMicroseconds:    maximum,
		BudgetMicroseconds: budget,
		BudgetPass:         maximum <= budget,
	}
}

func integerPercentile(sorted []int, percentile int) int {
	index := (len(sorted)*percentile + 99) / 100
	if index < 1 {
		index = 1
	}
	return sorted[index-1]
}

func integer64Percentile(sorted []int64, percentile int) int64 {
	index := (len(sorted)*percentile + 99) / 100
	if index < 1 {
		index = 1
	}
	return sorted[index-1]
}

func ValidateEvalThresholds(report EvalReport) error {
	switch {
	case report.RecallAtK < 0.90:
		return fmt.Errorf("Recall@K %.4f is below 0.90", report.RecallAtK)
	case report.MRR < 0.90:
		return fmt.Errorf("MRR %.4f is below 0.90", report.MRR)
	case report.NDCGAtK < 0.90:
		return fmt.Errorf("nDCG@K %.4f is below 0.90", report.NDCGAtK)
	case report.CitationCorrectness != 1 || report.CitationCoverage != 1:
		return errors.New("citation correctness and coverage must both be 1.0")
	case report.HiddenRecordLeakage != 0:
		return errors.New("hidden-record leakage must be zero")
	case report.GenerationCorrectness != 1:
		return errors.New("generation correctness must be 1.0")
	case report.NoResultCorrectness != 1:
		return errors.New("no-result correctness must be 1.0")
	case !report.PromptInjectionAsData:
		return errors.New("prompt-injection fixture was not retrieved as untrusted data")
	case !report.DeterministicLatency.BudgetPass:
		return errors.New("deterministic work budget exceeded")
	default:
		return nil
	}
}

func RenderEvalReport(report EvalReport) ([]byte, error) {
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func EvalReportSummary(report EvalReport) string {
	return fmt.Sprintf(
		"fixture-only Recall@K=%.3f MRR=%.3f nDCG@K=%.3f leakage=%d",
		report.RecallAtK,
		report.MRR,
		report.NDCGAtK,
		report.HiddenRecordLeakage,
	)
}

func normalizeEvalID(value string) string {
	return strings.TrimSpace(value)
}

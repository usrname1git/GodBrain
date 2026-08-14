package rag

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"time"
)

const (
	MaxRequestBodyBytes = 32 * 1024
	SearchTimeout       = 5 * time.Second
	HealthTimeout       = 3 * time.Second
	maxSearchAttempts   = 2
)

var ErrSearchSnapshotChanged = errors.New("RAG search snapshot changed during retrieval")

type API interface {
	Search(context.Context, SearchRequest) (SearchResponse, error)
	Health(context.Context) (HealthResponse, error)
}

func NewHandler(api API) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(writer http.ResponseWriter, request *http.Request) {
		setResponseHeaders(writer)
		if request.Method != http.MethodGet {
			writeAPIError(writer, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		ctx, cancel := context.WithTimeout(request.Context(), HealthTimeout)
		defer cancel()
		health, err := api.Health(ctx)
		if err != nil {
			writeAPIError(writer, http.StatusServiceUnavailable, "health_check_failed")
			return
		}
		status := http.StatusOK
		if !health.Ready {
			status = http.StatusServiceUnavailable
		}
		writeJSON(writer, status, health)
	})
	mux.HandleFunc("/v1/search", func(writer http.ResponseWriter, request *http.Request) {
		setResponseHeaders(writer)
		if request.Method != http.MethodPost {
			writeAPIError(writer, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" {
			writeAPIError(writer, http.StatusUnsupportedMediaType, "content_type_must_be_application_json")
			return
		}
		var searchRequest SearchRequest
		if err = decodeStrictJSON(writer, request, &searchRequest); err != nil {
			writeAPIError(writer, http.StatusBadRequest, "invalid_request")
			return
		}
		ctx, cancel := context.WithTimeout(request.Context(), SearchTimeout)
		defer cancel()
		response, err := searchConsistently(ctx, api, searchRequest)
		if err != nil {
			switch {
			case errors.Is(err, ErrQueryRequired),
				errors.Is(err, ErrQueryTooLarge),
				errors.Is(err, ErrInvalidTopK),
				errors.Is(err, ErrInvalidContext),
				errors.Is(err, ErrInvalidFilter),
				errors.Is(err, ErrInvalidConfidence):
				writeAPIError(writer, http.StatusBadRequest, err.Error())
			default:
				writeAPIError(writer, http.StatusServiceUnavailable, "search_unavailable")
			}
			return
		}
		writeJSON(writer, http.StatusOK, response)
	})
	return mux
}

func searchConsistently(ctx context.Context, api API, request SearchRequest) (SearchResponse, error) {
	for attempt := 0; attempt < maxSearchAttempts; attempt++ {
		before, err := api.Health(ctx)
		if err != nil || !before.Ready {
			if err != nil {
				return SearchResponse{}, err
			}
			return SearchResponse{}, ErrSearchSnapshotChanged
		}
		response, err := api.Search(ctx, request)
		if err != nil {
			return SearchResponse{}, err
		}
		after, err := api.Health(ctx)
		if err != nil {
			return SearchResponse{}, err
		}
		if sameSearchSnapshot(before, after, response) {
			return response, nil
		}
	}
	return SearchResponse{}, ErrSearchSnapshotChanged
}

func sameSearchSnapshot(before, after HealthResponse, response SearchResponse) bool {
	return before.Ready &&
		after.Ready &&
		before.Mongo == "ok" &&
		after.Mongo == "ok" &&
		before.ActiveGeneration != "" &&
		before.ActiveGeneration == after.ActiveGeneration &&
		before.ActiveGeneration == response.Generation &&
		before.BuildingGeneration == after.BuildingGeneration &&
		before.ProjectionVersion == after.ProjectionVersion &&
		before.ProjectionVersion == response.ProjectionVersion &&
		before.ProjectionSchema == after.ProjectionSchema &&
		before.IndexerVersion == after.IndexerVersion &&
		before.Counts == after.Counts &&
		sameOptionalTime(before.LatestCommittedAt, after.LatestCommittedAt) &&
		sameOptionalTime(before.LatestProjectedAt, after.LatestProjectedAt)
}

func sameOptionalTime(left, right *time.Time) bool {
	switch {
	case left == nil && right == nil:
		return true
	case left == nil || right == nil:
		return false
	default:
		return left.Equal(*right)
	}
}

func decodeStrictJSON(writer http.ResponseWriter, request *http.Request, destination any) error {
	reader := http.MaxBytesReader(writer, request.Body, MaxRequestBodyBytes)
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(destination); err != nil {
		return err
	}
	if _, err = decoder.Token(); err != io.EOF {
		return errors.New("request must contain exactly one JSON document")
	}
	return nil
}

func setResponseHeaders(writer http.ResponseWriter) {
	writer.Header().Set("Content-Type", "application/json")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.Header().Set("Cache-Control", "no-store")
}

func writeAPIError(writer http.ResponseWriter, status int, message string) {
	writeJSON(writer, status, struct {
		Error string `json:"error"`
	}{Error: message})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

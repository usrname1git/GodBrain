package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"godbrain_core/memory_store"
	"godbrain_core/memory_store/rag"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const maxInputBytes = 15 * 1024 * 1024

var (
	errInputTooLarge = errors.New("input payload exceeds maximum size of 15 MiB")
	errNoInput       = errors.New("no JSON payload received on stdin")
)

func readInput(reader io.Reader) ([]byte, error) {
	limitedReader := io.LimitReader(reader, maxInputBytes+1)
	inputData, err := io.ReadAll(limitedReader)
	if err != nil {
		return nil, err
	}
	if len(inputData) > maxInputBytes {
		return nil, errInputTooLarge
	}
	if len(inputData) == 0 {
		return nil, errNoInput
	}
	return inputData, nil
}

func failWithEnvelope(msg string, err error) error {
	errDetails := ""
	if err != nil {
		errDetails = err.Error()
		log.Printf("Fatal: %s: %v", msg, err)
	} else {
		log.Printf("Fatal: %s", msg)
	}

	env := memorystore.ErrorEnvelope{
		Error:   msg,
		Details: errDetails,
	}

	_ = json.NewEncoder(os.Stdout).Encode(env)
	return errors.New(msg)
}

func run() error {
	// 1. Strict Logging constraints (Logs ONLY to stderr)
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	// 2. Load and mask MongoDB URI
	uri := os.Getenv("MONGODB_URI")
	if uri == "" {
		return failWithEnvelope("MONGODB_URI environment variable is not set", nil)
	}

	// 3. Graceful shutdown / Context constraints (e.g. max 30 seconds for ingestion)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("Received termination signal, shutting down gracefully...")
		cancel()
	}()

	// Connect to Mongo
	clientOptions := options.Client().ApplyURI(uri)
	client, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		return failWithEnvelope("Failed to connect to MongoDB", err)
	}
	defer func() {
		if err := client.Disconnect(context.Background()); err != nil {
			log.Printf("Error disconnecting from MongoDB: %v", err)
		}
	}()

	// Ping check
	if err := client.Ping(ctx, nil); err != nil {
		return failWithEnvelope("Failed to ping MongoDB", err)
	}

	dbName := os.Getenv("MONGODB_DB_NAME")
	if dbName == "" {
		dbName = "godbrain"
	}
	db := client.Database(dbName)
	embeddingRuntime, err := rag.EmbeddingRuntimeFromEnvironment()
	if err != nil {
		return failWithEnvelope("Invalid embedding configuration", err)
	}

	// 4. Schema/Index-init (Idempotent)
	if err := memorystore.EnsureIndexes(ctx, db); err != nil {
		return failWithEnvelope("Failed to ensure indexes", err)
	}
	if err := rag.EnsureIndexes(ctx, db, embeddingRuntime); err != nil {
		return failWithEnvelope("Failed to ensure RAG projection indexes", err)
	}

	// 5. Read EXACTLY ONE JSON document below MongoDB's 16 MiB document limit.
	inputData, err := readInput(os.Stdin)
	if err != nil {
		switch {
		case errors.Is(err, errInputTooLarge), errors.Is(err, errNoInput):
			return failWithEnvelope(err.Error(), nil)
		default:
			return failWithEnvelope("Failed to read from stdin", err)
		}
	}

	var payload memorystore.DistillationPayload
	decoder := json.NewDecoder(bytes.NewReader(inputData))
	decoder.DisallowUnknownFields() // Strict schema matching
	if err := decoder.Decode(&payload); err != nil {
		return failWithEnvelope("Failed to parse JSON payload", err)
	}

	// Verify exactly one document (no trailing garbage)
	if _, err := decoder.Token(); err != io.EOF {
		return failWithEnvelope("Multiple JSON documents or trailing garbage found in input", nil)
	}
	if err := memorystore.ValidatePreIngestionPayload(payload); err != nil {
		return failWithEnvelope("Payload validation failed", err)
	}

	// 6. Ingestion Pipeline
	store := memorystore.NewStore(db)

	extractorID := payload.ExtractorID
	if extractorID == "" {
		extractorID = "Librarian-CPP-Colibri"
	}
	irun, created, err := store.StartIngestionWithMetadata(ctx, payload.Payload.Provenance.SourceHash, payload.Payload.Provenance.SourceID, extractorID, payload.ExtractorVersion, payload.SchemaVersion, nil, payload.Document)
	if err != nil {
		return failWithEnvelope("StartIngestion failed", err)
	}

	status := "committed"
	inserts := 0

	if !created && irun.Status == memorystore.StatusStaging {
		return failWithEnvelope("Concurrent ingestion detected: run is currently in staging", nil)
	}
	if !created && irun.Status == memorystore.StatusValidated {
		return failWithEnvelope("Concurrent ingestion detected: run is currently validating", nil)
	}

	if !created && irun.Status == memorystore.StatusCommitted {
		// Idempotent No-Op
		log.Printf("Run %s is already committed. Idempotent no-op.", irun.RunID)
		status = "idempotent_noop"
	} else {
		// Write Data
		if irun.Status == memorystore.StatusStaging {
			err = store.StageDistillation(ctx, irun.RunID, irun.LeaseToken, payload)
			if err != nil {
				errStr := err.Error()
				_ = memorystore.TransitionRunState(context.Background(), db, irun.RunID, memorystore.StatusStaging, memorystore.StatusFailed, irun.LeaseToken, &errStr)
				return failWithEnvelope("StageDistillation failed", err)
			}

			inserts, err = store.CountRunNodeLinks(ctx, irun.RunID)
			if err != nil {
				errStr := err.Error()
				_ = memorystore.TransitionRunState(context.Background(), db, irun.RunID, memorystore.StatusStaging, memorystore.StatusFailed, irun.LeaseToken, &errStr)
				return failWithEnvelope("Failed to count staged knowledge nodes", err)
			}

			err = memorystore.TransitionRunState(ctx, db, irun.RunID, memorystore.StatusStaging, memorystore.StatusValidated, irun.LeaseToken, nil)
			if err != nil {
				return failWithEnvelope("Transition to validated failed", err)
			}
		}

		err = memorystore.TransitionRunState(ctx, db, irun.RunID, memorystore.StatusValidated, memorystore.StatusCommitted, irun.LeaseToken, nil)
		if err != nil {
			return failWithEnvelope("Transition to committed failed", err)
		}
	}

	// A committed run is not acknowledged until its derivative retrieval projection
	// is confirmed. Retrying an already committed ingestion repairs this projection.
	if err = rag.NewProjector(db, embeddingRuntime).ProjectCommittedRun(ctx, irun.RunID); err != nil {
		return failWithEnvelope("Committed ingestion RAG projection failed", err)
	}

	// 7. Write EXACTLY ONE JSON Response to stdout
	receipt := memorystore.StoreReceipt{
		RunID:         irun.RunID,
		RecordID:      irun.ID.Hex(),
		Version:       irun.ExtractorVer,
		SchemaVersion: irun.SchemaVersion,
		Status:        status,
		InsertCount:   inserts,
		UpdateCount:   0,
		Timestamp:     time.Now().UTC(),
	}

	if err := json.NewEncoder(os.Stdout).Encode(receipt); err != nil {
		return failWithEnvelope("Failed to write receipt to stdout", err)
	}

	return nil
}

func main() {
	if err := run(); err != nil {
		os.Exit(1) // Fallback just in case, failWithEnvelope should have handled it
	}
}

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

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

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

	// 4. Schema/Index-init (Idempotent)
	if err := memorystore.EnsureIndexes(ctx, db); err != nil {
		return failWithEnvelope("Failed to ensure indexes", err)
	}

	// 5. Read EXACTLY ONE JSON document (Limit to 50MB to prevent memory exhaustion)
	const maxBytes = 50 * 1024 * 1024
	limitedReader := io.LimitReader(os.Stdin, maxBytes+1)
	inputData, err := io.ReadAll(limitedReader)
	if err != nil {
		return failWithEnvelope("Failed to read from stdin", err)
	}
	if len(inputData) > maxBytes {
		return failWithEnvelope("Input payload exceeds maximum size of 50MB", nil)
	}
	if len(inputData) == 0 {
		return failWithEnvelope("No JSON payload received on stdin", nil)
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

	// 6. Ingestion Pipeline
	store := memorystore.NewStore(db)

	irun, created, err := store.StartIngestion(ctx, payload.Payload.Provenance.SourceHash, "Librarian-CPP-Colibri", payload.ExtractorVersion, payload.SchemaVersion, nil)
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
			err = store.StageDistillation(ctx, irun.RunID, payload)
			if err != nil {
				errStr := err.Error()
				_ = memorystore.TransitionRunState(context.Background(), db, irun.RunID, memorystore.StatusStaging, memorystore.StatusFailed, &errStr)
				return failWithEnvelope("StageDistillation failed", err)
			}

			err = memorystore.TransitionRunState(ctx, db, irun.RunID, memorystore.StatusStaging, memorystore.StatusValidated, nil)
			if err != nil {
				return failWithEnvelope("Transition to validated failed", err)
			}
		}

		err = memorystore.TransitionRunState(ctx, db, irun.RunID, memorystore.StatusValidated, memorystore.StatusCommitted, nil)
		if err != nil {
			return failWithEnvelope("Transition to committed failed", err)
		}

		inserts = len(payload.Payload.Claims)
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

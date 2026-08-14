package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"godbrain_core/memory_store/rag"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if err := run(); err != nil {
		log.Printf("RAG rebuild failed: %v", err)
		os.Exit(1)
	}
}

func run() error {
	uri := os.Getenv("MONGODB_URI")
	if uri == "" {
		return errors.New("MONGODB_URI environment variable is not set")
	}
	dbName := os.Getenv("MONGODB_DB_NAME")
	if dbName == "" {
		dbName = "godbrain"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		return errors.New("failed to connect to MongoDB")
	}
	defer func() {
		disconnectCtx, disconnectCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer disconnectCancel()
		_ = client.Disconnect(disconnectCtx)
	}()
	if err = client.Ping(ctx, nil); err != nil {
		return errors.New("failed to ping MongoDB")
	}
	db := client.Database(dbName)
	embeddingRuntime, err := rag.EmbeddingRuntimeFromEnvironment()
	if err != nil {
		return fmt.Errorf("invalid embedding configuration: %w", err)
	}
	if err = rag.EnsureIndexes(ctx, db, embeddingRuntime); err != nil {
		return fmt.Errorf("failed to ensure RAG indexes: %w", err)
	}
	report, err := rag.NewProjector(db, embeddingRuntime).Rebuild(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(report)
}

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"godbrain_core/memory_store/rag"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if err := run(); err != nil {
		log.Printf("RAG service stopped: %v", err)
		os.Exit(1)
	}
}

func run() error {
	uri := os.Getenv("MONGODB_URI")
	if uri == "" {
		return errors.New("MONGODB_URI environment variable is not set")
	}
	port, err := servicePort(os.Getenv("GODBRAIN_RAG_PORT"))
	if err != nil {
		return err
	}
	dbName := os.Getenv("MONGODB_DB_NAME")
	if dbName == "" {
		dbName = "godbrain"
	}

	connectCtx, connectCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer connectCancel()
	client, err := mongo.Connect(connectCtx, options.Client().ApplyURI(uri))
	if err != nil {
		return errors.New("failed to connect to MongoDB")
	}
	defer func() {
		disconnectCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = client.Disconnect(disconnectCtx)
	}()
	if err = client.Ping(connectCtx, nil); err != nil {
		return errors.New("failed to ping MongoDB")
	}
	db := client.Database(dbName)
	embeddingRuntime, err := rag.EmbeddingRuntimeFromEnvironment()
	if err != nil {
		return fmt.Errorf("invalid embedding configuration: %w", err)
	}
	if err = rag.EnsureIndexes(connectCtx, db, embeddingRuntime); err != nil {
		return fmt.Errorf("failed to ensure RAG indexes: %w", err)
	}

	engine := rag.NewEngine(db, rag.Config{
		PreferredSchemaVersion: os.Getenv("GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION"),
		EmbeddingRuntime:       embeddingRuntime,
	})
	server := &http.Server{
		Addr:              "127.0.0.1:" + strconv.Itoa(port),
		Handler:           rag.NewHandler(engine),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       6 * time.Second,
		WriteTimeout:      8 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}

	serverErrors := make(chan error, 1)
	go func() {
		log.Printf("RAG service listening on 127.0.0.1:%d", port)
		serverErrors <- server.ListenAndServe()
	}()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)

	select {
	case signal := <-signals:
		log.Printf("Received %s; shutting down", signal)
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	case err = <-serverErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func servicePort(value string) (int, error) {
	if value == "" {
		return 8084, nil
	}
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return 0, errors.New("GODBRAIN_RAG_PORT must be an integer from 1 through 65535")
	}
	return port, nil
}

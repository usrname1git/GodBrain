package rag

import (
	"context"
	"time"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func EnsureIndexes(ctx context.Context, db *mongo.Database) error {
	if _, err := db.Collection("ingestion_runs").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "status", Value: 1},
			{Key: "updated_at", Value: -1},
			{Key: "run_id", Value: 1},
		},
		Options: options.Index().SetName("committed_run_projection"),
	}); err != nil {
		return err
	}
	if _, err := db.Collection("run_node_links").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "run_id", Value: 1},
			{Key: "node_id", Value: 1},
			{Key: "created_at", Value: 1},
		},
		Options: options.Index().SetName("rag_run_link_scan"),
	}); err != nil {
		return err
	}

	documents := db.Collection(DocumentsCollection)
	if _, err := documents.Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "node_id", Value: 1},
			},
			Options: options.Index().SetName("rag_document_identity").SetUnique(true),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "content", Value: "text"},
				{Key: "kind", Value: "text"},
				{Key: "sector", Value: "text"},
				{Key: "status", Value: "text"},
			},
			Options: options.Index().
				SetName("rag_lexical_text").
				SetDefaultLanguage("none").
				SetWeights(bson.M{"content": 10, "kind": 3, "sector": 3, "status": 1}),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "kind", Value: 1},
				{Key: "status", Value: 1},
				{Key: "sector", Value: 1},
				{Key: "schema_version", Value: 1},
				{Key: "confidence", Value: -1},
				{Key: "node_created_at", Value: -1},
				{Key: "stable_id", Value: 1},
			},
			Options: options.Index().SetName("rag_metadata_rank"),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "stable_id", Value: 1},
				{Key: "node_version", Value: 1},
			},
			Options: options.Index().SetName("rag_semantic_identity"),
		},
	}); err != nil {
		return err
	}

	provenance := db.Collection(ProvenanceCollection)
	if _, err := provenance.Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "node_id", Value: 1},
				{Key: "run_id", Value: 1},
			},
			Options: options.Index().SetName("rag_provenance_identity").SetUnique(true),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "node_id", Value: 1},
				{Key: "source_hash", Value: 1},
				{Key: "external_source_id", Value: 1},
				{Key: "run_id", Value: 1},
			},
			Options: options.Index().SetName("rag_provenance_lookup"),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "run_id", Value: 1},
				{Key: "node_id", Value: 1},
			},
			Options: options.Index().SetName("rag_provenance_run"),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "committed_at", Value: -1},
			},
			Options: options.Index().SetName("rag_provenance_freshness"),
		},
		{
			Keys: bson.D{
				{Key: "generation", Value: 1},
				{Key: "projected_at", Value: -1},
			},
			Options: options.Index().SetName("rag_projection_freshness"),
		},
	}); err != nil {
		return err
	}

	now := time.Now().UTC()
	initialGeneration := "live-" + uuid.NewString()
	_, err := db.Collection(MetadataCollection).UpdateOne(
		ctx,
		bson.M{"_id": metadataID},
		bson.M{"$setOnInsert": bson.M{
			"active_generation":  initialGeneration,
			"projection_version": ProjectionVersion,
			"projection_schema":  ProjectionSchema,
			"indexer_version":    IndexerVersion,
			"active_since":       now,
			"updated_at":         now,
		}},
		options.Update().SetUpsert(true),
	)
	return err
}

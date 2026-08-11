package memorystore

import (
	"context"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// EnsureIndexes creates all required indexes for the Alexandria data model.
// This function is idempotent and safe to run on startup.
func EnsureIndexes(ctx context.Context, db *mongo.Database) error {
	// 1. Sources: Unique by source_hash
	_, err := db.Collection("sources").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys:    bson.D{{Key: "source_hash", Value: 1}},
		Options: options.Index().SetUnique(true),
	})
	if err != nil {
		return err
	}

	// 2. Chunks: Unique by (source_hash, chunk_index)
	_, err = db.Collection("chunks").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "source_hash", Value: 1},
			{Key: "chunk_index", Value: 1},
		},
		Options: options.Index().SetUnique(true),
	})
	if err != nil {
		return err
	}

	// 3. Knowledge Nodes
	_, err = db.Collection("knowledge_nodes").Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys:    bson.D{{Key: "stable_id", Value: 1}, {Key: "version", Value: 1}}, // Unique ID based on hash of content + kind AND version
			Options: options.Index().SetUnique(true),
		},
		{
			Keys: bson.D{
				{Key: "kind", Value: 1},
				{Key: "status", Value: 1},
				{Key: "sector", Value: 1},
			}, // Compound index for fast capability/filter queries
		},
	})
	if err != nil {
		return err
	}

	// 4. Knowledge Edges
	_, err = db.Collection("knowledge_edges").Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys:    bson.D{{Key: "stable_id", Value: 1}}, // Unique edge key (Hash of From+To+Type)
			Options: options.Index().SetUnique(true),
		},
		{
			Keys: bson.D{{Key: "from_id", Value: 1}, {Key: "edge_type", Value: 1}},
		},
		{
			Keys: bson.D{{Key: "to_id", Value: 1}, {Key: "edge_type", Value: 1}},
		},
	})
	if err != nil {
		return err
	}

	// 5. Ingestion Runs: Unique idempotency key (excluding failed runs)
	_, err = db.Collection("ingestion_runs").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "source_hash", Value: 1},
			{Key: "extractor_id", Value: 1},
			{Key: "extractor_version", Value: 1},
			{Key: "schema_version", Value: 1},
		},
		Options: options.Index().SetUnique(true).SetPartialFilterExpression(bson.M{
			"active": true,
		}),
	})
	if err != nil {
		return err
	}

	// 6. Skills: Enforce uniqueness by Name
	_, err = db.Collection("skills").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys:    bson.D{{Key: "name", Value: 1}},
		Options: options.Index().SetUnique(true),
	})
	if err != nil {
		return err
	}

	return nil
}

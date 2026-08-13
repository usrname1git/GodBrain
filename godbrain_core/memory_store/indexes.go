package memorystore

import (
	"context"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
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

	// Replace earlier observation identities that did not distinguish source files.
	for _, name := range []string{"source_hash_1_external_source_id_1", "source_observation_identity"} {
		if err = dropIndexIfExists(ctx, db.Collection("source_observations"), name); err != nil {
			return err
		}
	}

	// Source Observations: one immutable record per complete ingestion identity.
	_, err = db.Collection("source_observations").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "source_hash", Value: 1},
			{Key: "external_source_id", Value: 1},
			{Key: "extractor_id", Value: 1},
			{Key: "extractor_version", Value: 1},
			{Key: "schema_version", Value: 1},
			{Key: "document.file_sha256", Value: 1},
		},
		Options: options.Index().SetName("source_observation_file_identity").SetUnique(true),
	})
	if err != nil {
		return err
	}

	// Replace the source-only chunk identity with extractor-aware chunks.
	if err = dropIndexIfExists(ctx, db.Collection("chunks"), "source_hash_1_chunk_index_1"); err != nil {
		return err
	}

	// 2. Chunks: immutable per source and extractor/schema identity.
	_, err = db.Collection("chunks").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys: bson.D{
			{Key: "source_hash", Value: 1},
			{Key: "extractor_id", Value: 1},
			{Key: "extractor_version", Value: 1},
			{Key: "schema_version", Value: 1},
			{Key: "chunk_index", Value: 1},
		},
		Options: options.Index().SetName("source_chunk_extractor_identity").SetUnique(true),
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

	// 4. Run-to-node associations own ingestion visibility; nodes remain immutable.
	_, err = db.Collection("run_node_links").Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys:    bson.D{{Key: "run_id", Value: 1}, {Key: "node_id", Value: 1}},
			Options: options.Index().SetUnique(true),
		},
		{
			Keys: bson.D{{Key: "node_id", Value: 1}},
		},
	})
	if err != nil {
		return err
	}
	if err = migrateLegacyNodeOwnership(ctx, db); err != nil {
		return err
	}

	// 5. Knowledge Edges
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

	// 6. Ingestion Runs: Unique idempotency key (excluding failed runs)
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

	// 7. Skills: Enforce uniqueness by Name
	_, err = db.Collection("skills").Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys:    bson.D{{Key: "name", Value: 1}},
		Options: options.Index().SetUnique(true),
	})
	if err != nil {
		return err
	}

	return nil
}

func dropIndexIfExists(ctx context.Context, collection *mongo.Collection, name string) error {
	_, err := collection.Indexes().DropOne(ctx, name)
	if err == nil {
		return nil
	}
	var commandErr mongo.CommandError
	if errors.As(err, &commandErr) && (commandErr.Code == 26 || commandErr.Code == 27) {
		return nil
	}
	return err
}

func migrateLegacyNodeOwnership(ctx context.Context, db *mongo.Database) error {
	type legacyNode struct {
		ID        primitive.ObjectID `bson:"_id"`
		RunID     string             `bson:"ingestion_run_id"`
		StableID  string             `bson:"stable_id"`
		Version   string             `bson:"version"`
		CreatedAt time.Time          `bson:"created_at"`
	}

	nodes := db.Collection("knowledge_nodes")
	cursor, err := nodes.Find(ctx, bson.M{
		"ingestion_run_id": bson.M{"$type": "string", "$ne": ""},
	})
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)

	var legacyNodes []legacyNode
	for cursor.Next(ctx) {
		var node legacyNode
		if err = cursor.Decode(&node); err != nil {
			return err
		}
		legacyNodes = append(legacyNodes, node)
	}
	if err = cursor.Err(); err != nil {
		return err
	}

	links := db.Collection("run_node_links")
	for _, node := range legacyNodes {
		if _, err = links.UpdateOne(ctx,
			bson.M{"run_id": node.RunID, "node_id": node.ID},
			bson.M{"$setOnInsert": bson.M{
				"run_id":        node.RunID,
				"node_id":       node.ID,
				"stable_id":     node.StableID,
				"node_version":  node.Version,
				"attempt_token": "legacy-migration",
				"created_at":    node.CreatedAt,
			}},
			options.Update().SetUpsert(true),
		); err != nil {
			return err
		}
		if _, err = nodes.UpdateOne(ctx,
			bson.M{"_id": node.ID, "ingestion_run_id": node.RunID},
			bson.M{"$unset": bson.M{"ingestion_run_id": "", "lease_token": ""}},
		); err != nil {
			return err
		}
	}

	_, err = db.Collection("sources").UpdateMany(ctx,
		bson.M{"$or": []bson.M{
			{"ingestion_run_id": bson.M{"$exists": true}},
			{"external_source_id": bson.M{"$exists": true}},
		}},
		bson.M{"$unset": bson.M{"ingestion_run_id": "", "external_source_id": ""}},
	)
	return err
}

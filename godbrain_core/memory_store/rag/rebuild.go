package rag

import (
	"context"
	"errors"
	"fmt"
	"time"

	memorystore "godbrain_core/memory_store"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const defaultRetiredGenerationGrace = 30 * time.Second

func (p *Projector) Rebuild(ctx context.Context) (report RebuildReport, err error) {
	report.StartedAt = time.Now().UTC()
	if err = p.CleanupRetiredGenerations(ctx, defaultRetiredGenerationGrace); err != nil {
		return report, err
	}

	metadata, err := p.Metadata(ctx)
	if err != nil {
		return report, err
	}
	generation := "rebuild-" + uuid.NewString()
	report.Generation = generation
	report.PreviousGeneration = metadata.ActiveGeneration
	startedAt := time.Now().UTC()
	var acquired Metadata
	err = p.db.Collection(MetadataCollection).FindOneAndUpdate(
		ctx,
		bson.M{
			"_id": metadataID,
			"$or": bson.A{
				bson.M{"building_generation": bson.M{"$exists": false}},
				bson.M{"building_generation": ""},
			},
		},
		bson.M{"$set": bson.M{
			"building_generation": generation,
			"build_started_at":    startedAt,
			"updated_at":          startedAt,
		}},
		options.FindOneAndUpdate().SetReturnDocument(options.After),
	).Decode(&acquired)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return report, ErrRebuildInProgress
	}
	if err != nil {
		return report, err
	}

	switched := false
	defer func() {
		if switched {
			return
		}
		abortCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		retiredAt := time.Now().UTC()
		_, _ = p.db.Collection(MetadataCollection).UpdateOne(
			abortCtx,
			bson.M{"_id": metadataID, "building_generation": generation},
			bson.M{
				"$unset": bson.M{"building_generation": "", "build_started_at": ""},
				"$push": bson.M{"retired_generations": RetiredGeneration{
					Generation: generation,
					RetiredAt:  retiredAt,
				}},
				"$set": bson.M{"updated_at": retiredAt},
			},
		)
	}()

	for attempt := 0; attempt < 3; attempt++ {
		if err = p.projectAllCommittedRuns(ctx, generation); err != nil {
			return report, err
		}
		report.Counts, err = p.CorpusCounts(ctx, generation)
		if err != nil {
			return report, err
		}
		if report.Counts.CommittedNodes == report.Counts.ProjectedNodes &&
			report.Counts.CommittedLinks == report.Counts.ProjectedLinks {
			break
		}
		if attempt == 2 {
			return report, fmt.Errorf("%w: committed nodes/links %d/%d, projected %d/%d",
				ErrProjectionIncomplete,
				report.Counts.CommittedNodes,
				report.Counts.CommittedLinks,
				report.Counts.ProjectedNodes,
				report.Counts.ProjectedLinks,
			)
		}
	}

	completedAt := time.Now().UTC()
	result, err := p.db.Collection(MetadataCollection).UpdateOne(
		ctx,
		bson.M{
			"_id":                 metadataID,
			"active_generation":   metadata.ActiveGeneration,
			"building_generation": generation,
		},
		bson.M{
			"$set": bson.M{
				"active_generation":  generation,
				"projection_version": ProjectionVersion,
				"projection_schema":  ProjectionSchema,
				"indexer_version":    IndexerVersion,
				"active_since":       completedAt,
				"last_rebuild_at":    completedAt,
				"updated_at":         completedAt,
			},
			"$unset": bson.M{"building_generation": "", "build_started_at": ""},
			"$push": bson.M{"retired_generations": RetiredGeneration{
				Generation: metadata.ActiveGeneration,
				RetiredAt:  completedAt,
			}},
		},
	)
	if err != nil {
		return report, err
	}
	if result.MatchedCount != 1 {
		return report, errors.New("RAG generation changed during rebuild; refusing to switch")
	}
	switched = true
	report.CompletedAt = completedAt
	return report, p.CleanupRetiredGenerations(ctx, defaultRetiredGenerationGrace)
}

func (p *Projector) projectAllCommittedRuns(ctx context.Context, generation string) error {
	cursor, err := p.db.Collection("ingestion_runs").Find(
		ctx,
		bson.M{"status": memorystore.StatusCommitted},
		options.Find().SetSort(bson.D{{Key: "run_id", Value: 1}}).SetProjection(bson.M{"run_id": 1}),
	)
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)

	for cursor.Next(ctx) {
		var runRef struct {
			RunID string `bson:"run_id"`
		}
		if err = cursor.Decode(&runRef); err != nil {
			return err
		}
		run, nodes, loadErr := p.loadCommittedRun(ctx, runRef.RunID)
		if loadErr != nil {
			return loadErr
		}
		if err = p.projectRun(ctx, run, nodes, []string{generation}); err != nil {
			return err
		}
	}
	return cursor.Err()
}

func (p *Projector) CleanupRetiredGenerations(ctx context.Context, grace time.Duration) error {
	metadata, err := p.Metadata(ctx)
	if err != nil {
		return err
	}
	cutoff := time.Now().UTC().Add(-grace)
	for _, retired := range metadata.RetiredGenerations {
		if retired.Generation == "" ||
			retired.Generation == metadata.ActiveGeneration ||
			retired.Generation == metadata.BuildingGeneration ||
			!retired.RetiredAt.Before(cutoff) {
			continue
		}
		if _, err = p.db.Collection(DocumentsCollection).DeleteMany(ctx, bson.M{"generation": retired.Generation}); err != nil {
			return err
		}
		if _, err = p.db.Collection(ProvenanceCollection).DeleteMany(ctx, bson.M{"generation": retired.Generation}); err != nil {
			return err
		}
		if _, err = p.db.Collection(MetadataCollection).UpdateOne(
			ctx,
			bson.M{"_id": metadataID},
			bson.M{"$pull": bson.M{"retired_generations": bson.M{"generation": retired.Generation}}},
		); err != nil {
			return err
		}
	}
	return nil
}

func (p *Projector) CorpusCounts(ctx context.Context, generation string) (CorpusCounts, error) {
	var counts CorpusCounts
	var err error
	counts.CommittedRuns, err = p.db.Collection("ingestion_runs").CountDocuments(ctx, bson.M{"status": memorystore.StatusCommitted})
	if err != nil {
		return counts, err
	}
	counts.CommittedNodes, err = p.committedNodeCount(ctx)
	if err != nil {
		return counts, err
	}
	counts.CommittedLinks, err = p.committedLinkCount(ctx)
	if err != nil {
		return counts, err
	}
	counts.ProjectedNodes, err = p.db.Collection(DocumentsCollection).CountDocuments(ctx, bson.M{"generation": generation})
	if err != nil {
		return counts, err
	}
	counts.ProjectedLinks, err = p.db.Collection(ProvenanceCollection).CountDocuments(ctx, bson.M{"generation": generation})
	return counts, err
}

func (p *Projector) committedNodeCount(ctx context.Context) (int64, error) {
	return aggregateCount(ctx, p.db.Collection("ingestion_runs"), mongo.Pipeline{
		{{Key: "$match", Value: bson.M{"status": memorystore.StatusCommitted}}},
		{{Key: "$lookup", Value: bson.M{
			"from":         "run_node_links",
			"localField":   "run_id",
			"foreignField": "run_id",
			"as":           "links",
		}}},
		{{Key: "$unwind", Value: "$links"}},
		{{Key: "$group", Value: bson.M{"_id": "$links.node_id"}}},
		{{Key: "$count", Value: "count"}},
	})
}

func (p *Projector) committedLinkCount(ctx context.Context) (int64, error) {
	return aggregateCount(ctx, p.db.Collection("ingestion_runs"), mongo.Pipeline{
		{{Key: "$match", Value: bson.M{"status": memorystore.StatusCommitted}}},
		{{Key: "$lookup", Value: bson.M{
			"from":         "run_node_links",
			"localField":   "run_id",
			"foreignField": "run_id",
			"as":           "links",
		}}},
		{{Key: "$unwind", Value: "$links"}},
		{{Key: "$count", Value: "count"}},
	})
}

func aggregateCount(ctx context.Context, collection *mongo.Collection, pipeline mongo.Pipeline) (int64, error) {
	cursor, err := collection.Aggregate(ctx, pipeline)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)
	var rows []struct {
		Count int64 `bson:"count"`
	}
	if err = cursor.All(ctx, &rows); err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return rows[0].Count, nil
}

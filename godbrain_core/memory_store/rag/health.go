package rag

import (
	"context"
	"errors"
	"time"

	memorystore "godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.mongodb.org/mongo-driver/mongo/readpref"
)

type HealthResponse struct {
	Ready              bool         `json:"ready"`
	Mongo              string       `json:"mongo"`
	ActiveGeneration   string       `json:"active_generation,omitempty"`
	BuildingGeneration string       `json:"building_generation,omitempty"`
	ProjectionVersion  string       `json:"projection_version,omitempty"`
	ProjectionSchema   string       `json:"projection_schema,omitempty"`
	IndexerVersion     string       `json:"indexer_version,omitempty"`
	Counts             CorpusCounts `json:"counts"`
	LegacyNodes        int64        `json:"legacy_nodes"`
	LatestCommittedAt  *time.Time   `json:"latest_committed_at,omitempty"`
	LatestProjectedAt  *time.Time   `json:"latest_projected_at,omitempty"`
	LagSeconds         float64      `json:"lag_seconds"`
	ReadinessReasons   []string     `json:"readiness_reasons"`
	CheckedAt          time.Time    `json:"checked_at"`
}

func (e *Engine) Health(ctx context.Context) (HealthResponse, error) {
	response := HealthResponse{
		Mongo:            "unavailable",
		ReadinessReasons: []string{},
		CheckedAt:        time.Now().UTC(),
	}
	if err := e.db.Client().Ping(ctx, readpref.Primary()); err != nil {
		response.ReadinessReasons = append(response.ReadinessReasons, "mongodb_unavailable")
		return response, nil
	}
	response.Mongo = "ok"

	metadata, err := e.projector.Metadata(ctx)
	if err != nil {
		if errors.Is(err, ErrProjectionMetadataMissing) {
			response.ReadinessReasons = append(response.ReadinessReasons, "projection_metadata_missing")
			return response, nil
		}
		return response, err
	}
	response.ActiveGeneration = metadata.ActiveGeneration
	response.BuildingGeneration = metadata.BuildingGeneration
	response.ProjectionVersion = metadata.ProjectionVersion
	response.ProjectionSchema = metadata.ProjectionSchema
	response.IndexerVersion = metadata.IndexerVersion

	response.Counts, err = e.projector.CorpusCounts(ctx, metadata.ActiveGeneration)
	if err != nil {
		return response, err
	}
	if response.Counts.CommittedNodes != response.Counts.ProjectedNodes ||
		response.Counts.CommittedLinks != response.Counts.ProjectedLinks {
		response.Counts, err = e.projector.CorpusCounts(ctx, metadata.ActiveGeneration)
		if err != nil {
			return response, err
		}
	}
	response.LegacyNodes, err = e.db.Collection("nodes").CountDocuments(ctx, bson.M{})
	if err != nil {
		return response, err
	}
	response.LatestCommittedAt, err = latestTime(
		ctx,
		e.db.Collection("ingestion_runs"),
		bson.M{"status": memorystore.StatusCommitted},
		"updated_at",
	)
	if err != nil {
		return response, err
	}
	response.LatestProjectedAt, err = latestTime(
		ctx,
		e.db.Collection(ProvenanceCollection),
		bson.M{"generation": metadata.ActiveGeneration},
		"projected_at",
	)
	if err != nil {
		return response, err
	}
	if response.LatestCommittedAt != nil &&
		(response.LatestProjectedAt == nil || response.LatestProjectedAt.Before(*response.LatestCommittedAt)) {
		if response.LatestProjectedAt == nil {
			response.LagSeconds = time.Since(*response.LatestCommittedAt).Seconds()
		} else {
			response.LagSeconds = response.LatestCommittedAt.Sub(*response.LatestProjectedAt).Seconds()
		}
	}

	if metadata.ActiveGeneration == "" {
		response.ReadinessReasons = append(response.ReadinessReasons, "active_generation_missing")
	}
	if metadata.ProjectionVersion != ProjectionVersion ||
		metadata.ProjectionSchema != ProjectionSchema ||
		metadata.IndexerVersion != IndexerVersion {
		response.ReadinessReasons = append(response.ReadinessReasons, "projection_version_mismatch")
	}
	if response.Counts.CommittedNodes != response.Counts.ProjectedNodes {
		response.ReadinessReasons = append(response.ReadinessReasons, "projected_node_count_mismatch")
	}
	if response.Counts.CommittedLinks != response.Counts.ProjectedLinks {
		response.ReadinessReasons = append(response.ReadinessReasons, "projected_provenance_count_mismatch")
	}
	response.Ready = len(response.ReadinessReasons) == 0
	return response, nil
}

func latestTime(
	ctx context.Context,
	collection *mongo.Collection,
	filter bson.M,
	field string,
) (*time.Time, error) {
	var row bson.M
	err := collection.FindOne(
		ctx,
		filter,
		options.FindOne().
			SetSort(bson.D{{Key: field, Value: -1}}).
			SetProjection(bson.M{field: 1}),
	).Decode(&row)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var value time.Time
	switch raw := row[field].(type) {
	case time.Time:
		value = raw
	case primitive.DateTime:
		value = raw.Time()
	default:
		return nil, nil
	}
	utc := value.UTC()
	return &utc, nil
}

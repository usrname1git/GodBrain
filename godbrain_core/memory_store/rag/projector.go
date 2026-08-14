package rag

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	memorystore "godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var (
	ErrProjectionMetadataMissing = errors.New("RAG projection metadata is missing")
	ErrRunNotCommitted           = errors.New("ingestion run is not committed")
	ErrProjectionIncomplete      = errors.New("RAG projection verification failed")
	ErrRebuildInProgress         = errors.New("RAG projection rebuild is already in progress")
)

type Projector struct {
	db      *mongo.Database
	runtime EmbeddingRuntime
}

type linkedNode struct {
	Link memorystore.RunNodeLink   `bson:"link"`
	Node memorystore.KnowledgeNode `bson:"node"`
}

type projectionTarget struct {
	Generation string
	Embedding  *EmbeddingIdentity
}

func NewProjector(db *mongo.Database, runtimes ...EmbeddingRuntime) *Projector {
	projector := &Projector{db: db}
	if len(runtimes) == 1 {
		projector.runtime = runtimes[0]
	}
	return projector
}

func (p *Projector) Metadata(ctx context.Context) (Metadata, error) {
	var metadata Metadata
	err := p.db.Collection(MetadataCollection).FindOne(ctx, bson.M{"_id": metadataID}).Decode(&metadata)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return Metadata{}, ErrProjectionMetadataMissing
	}
	return metadata, err
}

func (p *Projector) ProjectCommittedRun(ctx context.Context, runID string) error {
	run, nodes, err := p.loadCommittedRun(ctx, runID)
	if err != nil {
		return err
	}
	metadata, err := p.Metadata(ctx)
	if err != nil {
		return err
	}
	targets := projectionTargets(metadata)
	if len(targets) == 0 {
		return ErrProjectionMetadataMissing
	}
	return p.projectRun(ctx, run, nodes, targets)
}

func (p *Projector) loadCommittedRun(ctx context.Context, runID string) (memorystore.IngestionRun, []linkedNode, error) {
	var run memorystore.IngestionRun
	if err := p.db.Collection("ingestion_runs").FindOne(ctx, bson.M{
		"run_id": runID,
		"status": memorystore.StatusCommitted,
	}).Decode(&run); err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return run, nil, ErrRunNotCommitted
		}
		return run, nil, err
	}

	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: bson.M{"run_id": runID}}},
		{{Key: "$sort", Value: bson.D{{Key: "node_id", Value: 1}}}},
		{{Key: "$lookup", Value: bson.M{
			"from":         "knowledge_nodes",
			"localField":   "node_id",
			"foreignField": "_id",
			"as":           "node",
		}}},
		{{Key: "$unwind", Value: "$node"}},
		{{Key: "$project", Value: bson.M{
			"_id":  0,
			"link": "$$ROOT",
			"node": bson.M{
				"_id":            "$node._id",
				"stable_id":      "$node.stable_id",
				"version":        "$node.version",
				"kind":           "$node.kind",
				"status":         "$node.status",
				"sector":         "$node.sector",
				"content":        "$node.content",
				"confidence":     "$node.confidence",
				"evidence_spans": "$node.evidence_spans",
				"schema_version": "$node.schema_version",
				"created_at":     "$node.created_at",
			},
		}}},
	}
	cursor, err := p.db.Collection("run_node_links").Aggregate(ctx, pipeline)
	if err != nil {
		return run, nil, err
	}
	defer cursor.Close(ctx)

	var nodes []linkedNode
	if err = cursor.All(ctx, &nodes); err != nil {
		return run, nil, err
	}
	linkCount, err := p.db.Collection("run_node_links").CountDocuments(ctx, bson.M{"run_id": runID})
	if err != nil {
		return run, nil, err
	}
	if int64(len(nodes)) != linkCount {
		return run, nil, fmt.Errorf("%w: run %s has %d links but %d resolvable nodes", ErrProjectionIncomplete, runID, linkCount, len(nodes))
	}
	return run, nodes, nil
}

func (p *Projector) projectRun(ctx context.Context, run memorystore.IngestionRun, nodes []linkedNode, targets []projectionTarget) error {
	now := time.Now().UTC()
	for _, target := range targets {
		generation := target.Generation
		nodeIDs := make([]primitive.ObjectID, 0, len(nodes))
		for _, linked := range nodes {
			nodeIDs = append(nodeIDs, linked.Node.ID)
			document := Document{
				Generation:        generation,
				NodeID:            linked.Node.ID,
				StableID:          linked.Node.StableID,
				NodeVersion:       linked.Node.Version,
				Content:           linked.Node.Content,
				Kind:              linked.Node.Kind,
				Sector:            linked.Node.Sector,
				Status:            linked.Node.Status,
				Confidence:        linked.Node.Confidence,
				SchemaVersion:     linked.Node.SchemaVersion,
				EvidenceSpans:     linked.Node.EvidenceSpans,
				NodeCreatedAt:     linked.Node.CreatedAt,
				ProjectionVersion: ProjectionVersion,
				ProjectionSchema:  ProjectionSchema,
				IndexerVersion:    IndexerVersion,
				ProjectedAt:       now,
			}
			if err := p.upsertDocument(ctx, document); err != nil {
				return fmt.Errorf("project node %s into generation %s: %w", linked.Node.ID.Hex(), generation, err)
			}

			provenance := Provenance{
				Generation:       generation,
				NodeID:           linked.Node.ID,
				StableID:         linked.Node.StableID,
				NodeVersion:      linked.Node.Version,
				RunID:            run.RunID,
				SourceID:         run.SourceID,
				SourceHash:       run.SourceHash,
				ExternalSourceID: run.ExternalSourceID,
				ExtractorID:      run.ExtractorID,
				ExtractorVersion: run.ExtractorVer,
				SchemaVersion:    run.SchemaVersion,
				EvidenceSpans:    linked.Link.EvidenceSpans,
				CommittedAt:      run.UpdatedAt,
				ProjectedAt:      now,
			}
			if err := p.upsertProvenance(ctx, provenance); err != nil {
				return fmt.Errorf("project provenance for node %s into generation %s: %w", linked.Node.ID.Hex(), generation, err)
			}
			if target.Embedding != nil {
				if err := p.projectEmbedding(ctx, generation, linked.Node, *target.Embedding, now); err != nil {
					return fmt.Errorf("project embedding for node %s into generation %s: %w", linked.Node.ID.Hex(), generation, err)
				}
			}
		}
		if err := p.verifyRunProjection(ctx, generation, run.RunID, nodeIDs, target.Embedding); err != nil {
			return err
		}
	}
	return nil
}

func projectionTargets(metadata Metadata) []projectionTarget {
	targets := make([]projectionTarget, 0, 2)
	if metadata.ActiveGeneration != "" {
		targets = append(targets, projectionTarget{
			Generation: metadata.ActiveGeneration,
			Embedding:  metadata.Embedding,
		})
	}
	if metadata.BuildingGeneration != "" && metadata.BuildingGeneration != metadata.ActiveGeneration {
		targets = append(targets, projectionTarget{
			Generation: metadata.BuildingGeneration,
			Embedding:  metadata.BuildingEmbedding,
		})
	}
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].Generation < targets[j].Generation
	})
	return targets
}

func (p *Projector) projectEmbedding(
	ctx context.Context,
	generation string,
	node memorystore.KnowledgeNode,
	expected EmbeddingIdentity,
	projectedAt time.Time,
) error {
	if err := expected.Validate(); err != nil {
		return err
	}
	if p.runtime.Provider == nil || !p.runtime.Provider.Identity().Equal(expected) {
		return ErrEmbeddingUnavailable
	}
	normalized, inputHash := normalizeEmbeddingInput(node.Content)
	filter := embeddingIdentityFilter(generation, node.ID, expected)
	cacheFilter := embeddingIdentityFilter(generation, node.ID, expected)
	cacheFilter["input_hash"] = inputHash
	var existing EmbeddingRecord
	err := p.db.Collection(EmbeddingsCollection).FindOne(
		ctx,
		cacheFilter,
		options.FindOne().SetProjection(bson.M{"vector": 1}),
	).Decode(&existing)
	if err == nil && validEmbeddingVector(existing.Vector, expected.Dimension) {
		return nil
	}
	if err != nil && !errors.Is(err, mongo.ErrNoDocuments) {
		return err
	}
	vector, err := p.runtime.Provider.Embed(ctx, normalized)
	if err != nil {
		return err
	}
	if !validEmbeddingVector(vector, expected.Dimension) {
		return ErrEmbeddingResponse
	}
	record := bson.M{
		"generation":       generation,
		"node_id":          node.ID,
		"stable_id":        node.StableID,
		"node_version":     node.Version,
		"provider_kind":    expected.ProviderKind,
		"model_identifier": expected.ModelIdentifier,
		"model_revision":   expected.ModelRevision,
		"model_hash":       expected.ModelHash,
		"dimension":        expected.Dimension,
		"input_hash":       inputHash,
		"embedding_schema": expected.SchemaVersion,
		"indexer_version":  expected.IndexerVersion,
		"vector_backend":   expected.VectorBackend,
		"vector":           vector,
		"projected_at":     projectedAt,
	}
	_, err = p.db.Collection(EmbeddingsCollection).UpdateOne(
		ctx,
		filter,
		bson.M{"$set": record},
		options.Update().SetUpsert(true),
	)
	if mongo.IsDuplicateKeyError(err) {
		_, err = p.db.Collection(EmbeddingsCollection).UpdateOne(ctx, filter, bson.M{"$set": record})
	}
	return err
}

func embeddingIdentityFilter(
	generation string,
	nodeID primitive.ObjectID,
	identity EmbeddingIdentity,
) bson.M {
	return bson.M{
		"generation":       generation,
		"node_id":          nodeID,
		"provider_kind":    identity.ProviderKind,
		"model_identifier": identity.ModelIdentifier,
		"model_revision":   identity.ModelRevision,
		"model_hash":       identity.ModelHash,
		"embedding_schema": identity.SchemaVersion,
		"indexer_version":  identity.IndexerVersion,
		"dimension":        identity.Dimension,
		"vector_backend":   identity.VectorBackend,
	}
}

func (p *Projector) upsertDocument(ctx context.Context, document Document) error {
	filter := bson.M{"generation": document.Generation, "node_id": document.NodeID}
	update := bson.M{"$set": bson.M{
		"generation":         document.Generation,
		"node_id":            document.NodeID,
		"stable_id":          document.StableID,
		"node_version":       document.NodeVersion,
		"content":            document.Content,
		"kind":               document.Kind,
		"sector":             document.Sector,
		"status":             document.Status,
		"confidence":         document.Confidence,
		"schema_version":     document.SchemaVersion,
		"evidence_spans":     document.EvidenceSpans,
		"node_created_at":    document.NodeCreatedAt,
		"projection_version": document.ProjectionVersion,
		"projection_schema":  document.ProjectionSchema,
		"indexer_version":    document.IndexerVersion,
		"projected_at":       document.ProjectedAt,
	}}
	_, err := p.db.Collection(DocumentsCollection).UpdateOne(ctx, filter, update, options.Update().SetUpsert(true))
	if mongo.IsDuplicateKeyError(err) {
		_, err = p.db.Collection(DocumentsCollection).UpdateOne(ctx, filter, update)
	}
	return err
}

func (p *Projector) upsertProvenance(ctx context.Context, provenance Provenance) error {
	filter := bson.M{
		"generation": provenance.Generation,
		"node_id":    provenance.NodeID,
		"run_id":     provenance.RunID,
	}
	update := bson.M{"$set": bson.M{
		"generation":         provenance.Generation,
		"node_id":            provenance.NodeID,
		"stable_id":          provenance.StableID,
		"node_version":       provenance.NodeVersion,
		"run_id":             provenance.RunID,
		"source_id":          provenance.SourceID,
		"source_hash":        provenance.SourceHash,
		"external_source_id": provenance.ExternalSourceID,
		"extractor_id":       provenance.ExtractorID,
		"extractor_version":  provenance.ExtractorVersion,
		"schema_version":     provenance.SchemaVersion,
		"evidence_spans":     provenance.EvidenceSpans,
		"committed_at":       provenance.CommittedAt,
		"projected_at":       provenance.ProjectedAt,
	}}
	_, err := p.db.Collection(ProvenanceCollection).UpdateOne(ctx, filter, update, options.Update().SetUpsert(true))
	if mongo.IsDuplicateKeyError(err) {
		_, err = p.db.Collection(ProvenanceCollection).UpdateOne(ctx, filter, update)
	}
	return err
}

func (p *Projector) verifyRunProjection(
	ctx context.Context,
	generation, runID string,
	nodeIDs []primitive.ObjectID,
	embedding *EmbeddingIdentity,
) error {
	if len(nodeIDs) == 0 {
		return nil
	}
	unique := make(map[primitive.ObjectID]struct{}, len(nodeIDs))
	for _, nodeID := range nodeIDs {
		unique[nodeID] = struct{}{}
	}
	ids := make([]primitive.ObjectID, 0, len(unique))
	for nodeID := range unique {
		ids = append(ids, nodeID)
	}
	const batchSize = 500
	var documentCount, provenanceCount, embeddingCount int64
	for start := 0; start < len(ids); start += batchSize {
		end := start + batchSize
		if end > len(ids) {
			end = len(ids)
		}
		batch := ids[start:end]
		count, err := p.db.Collection(DocumentsCollection).CountDocuments(ctx, bson.M{
			"generation": generation,
			"node_id":    bson.M{"$in": batch},
		})
		if err != nil {
			return err
		}
		documentCount += count
		count, err = p.db.Collection(ProvenanceCollection).CountDocuments(ctx, bson.M{
			"generation": generation,
			"run_id":     runID,
			"node_id":    bson.M{"$in": batch},
		})
		if err != nil {
			return err
		}
		provenanceCount += count
		if embedding != nil {
			embeddingFilter := bson.M{
				"generation":       generation,
				"node_id":          bson.M{"$in": batch},
				"provider_kind":    embedding.ProviderKind,
				"model_identifier": embedding.ModelIdentifier,
				"model_revision":   embedding.ModelRevision,
				"model_hash":       embedding.ModelHash,
				"dimension":        embedding.Dimension,
				"embedding_schema": embedding.SchemaVersion,
				"indexer_version":  embedding.IndexerVersion,
				"vector_backend":   embedding.VectorBackend,
			}
			count, err = p.db.Collection(EmbeddingsCollection).CountDocuments(ctx, embeddingFilter)
			if err != nil {
				return err
			}
			embeddingCount += count
		}
	}
	expected := int64(len(ids))
	if documentCount != expected || provenanceCount != expected ||
		(embedding != nil && embeddingCount != expected) {
		return fmt.Errorf("%w: generation %s run %s expected %d nodes, found %d documents, %d provenance links, and %d embeddings", ErrProjectionIncomplete, generation, runID, expected, documentCount, provenanceCount, embeddingCount)
	}
	return nil
}

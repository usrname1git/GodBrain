package rag

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/text/unicode/norm"
)

const (
	DefaultGraphLimit = 250
	MaxGraphLimit     = 500
	MaxGraphLabel     = 80
	MaxDocumentID     = 128
)

var (
	ErrInvalidGraphLimit  = errors.New("graph limit is outside the allowed range")
	ErrDocumentIDRequired = errors.New("document id is required")
	ErrDocumentNotFound   = errors.New("document not found")
)

type GraphNode struct {
	NodeID     string  `json:"node_id"`
	StableID   string  `json:"stable_id"`
	Kind       string  `json:"kind"`
	Sector     string  `json:"sector"`
	Status     string  `json:"status"`
	Confidence float64 `json:"confidence"`
	Label      string  `json:"label"`
}

type GraphResponse struct {
	Generation        string      `json:"generation"`
	ProjectionVersion string      `json:"projection_version"`
	ProjectionSchema  string      `json:"projection_schema"`
	Count             int         `json:"count"`
	Truncated         bool        `json:"truncated"`
	Nodes             []GraphNode `json:"nodes"`
}

type DocumentResponse struct {
	NodeID        string  `json:"node_id"`
	StableID      string  `json:"stable_id"`
	NodeVersion   string  `json:"node_version"`
	Kind          string  `json:"kind"`
	Sector        string  `json:"sector"`
	Status        string  `json:"status"`
	Confidence    float64 `json:"confidence"`
	SchemaVersion string  `json:"schema_version"`
	Content       string  `json:"content"`
	Label         string  `json:"label"`
}

func (e *Engine) Graph(ctx context.Context, limit int) (GraphResponse, error) {
	if limit <= 0 {
		limit = DefaultGraphLimit
	}
	if limit > MaxGraphLimit {
		return GraphResponse{}, ErrInvalidGraphLimit
	}
	metadata, err := e.projector.Metadata(ctx)
	if err != nil {
		return GraphResponse{}, err
	}
	if metadata.ActiveGeneration == "" {
		return GraphResponse{}, ErrProjectionMetadataMissing
	}

	filter := bson.M{"generation": metadata.ActiveGeneration}
	opts := options.Find().
		SetSort(bson.D{{Key: "node_created_at", Value: -1}, {Key: "stable_id", Value: 1}}).
		SetLimit(int64(limit + 1)).
		SetProjection(bson.M{
			"node_id":    1,
			"stable_id":  1,
			"kind":       1,
			"sector":     1,
			"status":     1,
			"confidence": 1,
			"content":    1,
		})
	cursor, err := e.db.Collection(DocumentsCollection).Find(ctx, filter, opts)
	if err != nil {
		return GraphResponse{}, err
	}
	defer cursor.Close(ctx)

	var documents []Document
	if err = cursor.All(ctx, &documents); err != nil {
		return GraphResponse{}, err
	}
	truncated := len(documents) > limit
	if truncated {
		documents = documents[:limit]
	}
	nodes := make([]GraphNode, 0, len(documents))
	for _, document := range documents {
		nodes = append(nodes, GraphNode{
			NodeID:     document.NodeID.Hex(),
			StableID:   document.StableID,
			Kind:       document.Kind,
			Sector:     document.Sector,
			Status:     document.Status,
			Confidence: document.Confidence,
			Label:      graphLabel(document.Content, document.StableID),
		})
	}
	return GraphResponse{
		Generation:        metadata.ActiveGeneration,
		ProjectionVersion: ProjectionVersion,
		ProjectionSchema:  ProjectionSchema,
		Count:             len(nodes),
		Truncated:         truncated,
		Nodes:             nodes,
	}, nil
}

func (e *Engine) Document(ctx context.Context, id string) (DocumentResponse, error) {
	id = strings.TrimSpace(id)
	if id == "" || len(id) > MaxDocumentID {
		return DocumentResponse{}, ErrDocumentIDRequired
	}
	metadata, err := e.projector.Metadata(ctx)
	if err != nil {
		return DocumentResponse{}, err
	}
	if metadata.ActiveGeneration == "" {
		return DocumentResponse{}, ErrProjectionMetadataMissing
	}

	filter := bson.M{"generation": metadata.ActiveGeneration}
	if objectID, parseErr := primitive.ObjectIDFromHex(id); parseErr == nil {
		filter["node_id"] = objectID
	} else {
		filter["stable_id"] = id
	}

	var document Document
	err = e.db.Collection(DocumentsCollection).FindOne(ctx, filter).Decode(&document)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return DocumentResponse{}, ErrDocumentNotFound
	}
	if err != nil {
		return DocumentResponse{}, err
	}
	return DocumentResponse{
		NodeID:        document.NodeID.Hex(),
		StableID:      document.StableID,
		NodeVersion:   document.NodeVersion,
		Kind:          document.Kind,
		Sector:        document.Sector,
		Status:        document.Status,
		Confidence:    document.Confidence,
		SchemaVersion: document.SchemaVersion,
		Content:       document.Content,
		Label:         graphLabel(document.Content, document.StableID),
	}, nil
}

func graphLabel(content, fallback string) string {
	normalized := strings.Join(strings.Fields(norm.NFKC.String(content)), " ")
	if normalized == "" {
		return fallback
	}
	if utf8.RuneCountInString(normalized) <= MaxGraphLabel {
		return normalized
	}
	runes := []rune(normalized)
	return string(runes[:MaxGraphLabel])
}

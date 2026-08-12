package memorystore

import (
	"context"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const (
	StatusStaging   = "staging"
	StatusValidated = "validated"
	StatusCommitted = "committed"
	StatusFailed    = "failed"
)

var (
	ErrInvalidTransition = errors.New("invalid ingestion run state transition")
	ErrRunNotFound       = errors.New("ingestion run not found")
	ErrStateConflict     = errors.New("ingestion run is not in the expected state")
)

// TransitionRunState atomically updates the ingestion run's status only if it matches expectedCurrent and lease token.
func TransitionRunState(ctx context.Context, db *mongo.Database, runID string, expectedCurrent string, newStatus string, leaseToken string, errorMsg *string) error {
	valid := false

	// Enforce strict DAG transitions with retry semantics
	switch expectedCurrent {
	case StatusStaging:
		if newStatus == StatusValidated || newStatus == StatusFailed {
			valid = true
		}
	case StatusValidated:
		if newStatus == StatusCommitted || newStatus == StatusFailed {
			valid = true
		}
	}

	if !valid {
		return ErrInvalidTransition
	}

	coll := db.Collection("ingestion_runs")
	filter := bson.M{
		"run_id":      runID,
		"status":      expectedCurrent,
		"lease_token": leaseToken,
	}

	updateDoc := bson.M{
		"status":     newStatus,
		"updated_at": time.Now().UTC(),
	}
	
	if newStatus == StatusFailed {
		updateDoc["active"] = false
	}
	
	if errorMsg != nil {
		updateDoc["error_msg"] = *errorMsg
	}

	update := bson.M{"$set": updateDoc}

	res := coll.FindOneAndUpdate(ctx, filter, update, options.FindOneAndUpdate().SetReturnDocument(options.After))
	if res.Err() != nil {
		if res.Err() == mongo.ErrNoDocuments {
			// Differentiate between NotFound and StateConflict
			count, _ := coll.CountDocuments(ctx, bson.M{"run_id": runID})
			if count > 0 {
				return ErrStateConflict
			}
			return ErrRunNotFound
		}
		return res.Err()
	}

	return nil
}

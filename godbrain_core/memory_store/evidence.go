package memorystore

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

const (
	EvidenceLeaseMS  int64 = 120000
	DocumentTTLMS    int64 = 86400000
	HostTTLMS        int64 = 900000
	EvidenceAttempts       = 6
	EvidenceVersion        = "1.0.0"
)

type EvidenceRequest struct {
	Command      string `json:"command"`
	Action       string `json:"action"`
	ID           string `json:"id,omitempty"`
	LeaseToken   string `json:"lease_token,omitempty"`
	Outcome      string `json:"outcome,omitempty"`
	Reason       string `json:"reason,omitempty"`
	ObservedHash string `json:"observed_hash,omitempty"`
	Successor    string `json:"successor,omitempty"`
}

func ParseEvidenceRequest(input []byte) (EvidenceRequest, error) {
	var request EvidenceRequest
	decoder := json.NewDecoder(bytes.NewReader(input))
	start, err := decoder.Token()
	if err != nil {
		return request, err
	}
	if start != json.Delim('{') {
		return request, errors.New("evidence command must be an object")
	}
	fields := map[string]*string{
		"command": &request.Command, "action": &request.Action, "id": &request.ID,
		"lease_token": &request.LeaseToken, "outcome": &request.Outcome,
		"reason": &request.Reason, "observed_hash": &request.ObservedHash, "successor": &request.Successor,
	}
	seen := make(map[string]bool)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return request, err
		}
		key, ok := token.(string)
		target, known := fields[key]
		if !ok || !known || seen[key] {
			return request, errors.New("unknown or duplicate evidence field")
		}
		seen[key] = true
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return request, err
		}
		if len(raw) == 0 || raw[0] != '"' {
			return request, errors.New("evidence fields must be strings")
		}
		if err := json.Unmarshal(raw, target); err != nil {
			return request, err
		}
	}
	if end, err := decoder.Token(); err != nil || end != json.Delim('}') {
		return request, errors.New("unterminated evidence command")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return request, errors.New("multiple JSON documents or trailing data")
	}
	return request, ValidateEvidenceRequest(request)
}

type evidenceResult struct {
	Outcome      string `bson:"outcome" json:"outcome"`
	Reason       string `bson:"reason" json:"reason"`
	ObservedHash string `bson:"observed_hash" json:"observed_hash"`
	Successor    string `bson:"successor" json:"successor"`
}

type evidenceRow struct {
	ID                 string             `bson:"_id" json:"_id"`
	NodeID             primitive.ObjectID `bson:"node_id" json:"node_id"`
	NodeVersion        string             `bson:"node_version" json:"node_version"`
	ContentHash        string             `bson:"content_hash" json:"content_hash"`
	StableID           string             `bson:"stable_id" json:"stable_id"`
	Sector             string             `bson:"sector" json:"sector"`
	SourceRun          string             `bson:"source_run" json:"source_run"`
	SourceHash         string             `bson:"source_hash" json:"source_hash"`
	SourceURL          string             `bson:"source_url" json:"source_url"`
	State              string             `bson:"state" json:"state"`
	Profile            string             `bson:"profile" json:"profile"`
	Attempts           int                `bson:"attempts" json:"attempts"`
	NextCheckMS        int64              `bson:"next_check_ms" json:"next_check_ms"`
	LeaseUntilMS       int64              `bson:"lease_until_ms" json:"lease_until_ms"`
	CheckedAtMS        int64              `bson:"checked_at_ms" json:"checked_at_ms"`
	ExpiresAtMS        int64              `bson:"expires_at_ms" json:"expires_at_ms"`
	Reason             string             `bson:"reason" json:"reason"`
	LeaseToken         string             `bson:"lease_token,omitempty" json:"lease_token,omitempty"`
	LastToken          string             `bson:"last_token,omitempty" json:"last_token,omitempty"`
	LastResult         evidenceResult     `bson:"last_result,omitempty" json:"last_result,omitempty"`
	MaintenanceVersion string             `bson:"maintenance_version,omitempty" json:"maintenance_version,omitempty"`
}

func evidenceHash(content string) string {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(content))
	return hex.EncodeToString(hash.Sum(nil))
}

func EvidenceBinding(node, version, content string) string {
	return evidenceHash(node + "\x00" + version + "\x00" + evidenceHash(content))
}

func EvidenceBackoff(attempts int) int64 {
	if attempts >= EvidenceAttempts {
		return DocumentTTLMS
	}
	return int64(60000) << max(0, min(attempts-1, 4))
}

func EvidenceWindow(profile string, checked, expires, now int64) bool {
	ttl := DocumentTTLMS
	if profile == "host" {
		ttl = HostTTLMS
	} else if profile != "document" {
		return false
	}
	return checked > 0 && checked <= now && expires == checked+ttl && expires > now
}

func ValidateEvidenceRequest(r EvidenceRequest) error {
	isHex := func(value string, size int) bool {
		return len(value) == size && strings.Trim(value, "0123456789abcdef") == ""
	}
	valid := r.Command == "evidence"
	switch r.Action {
	case "next", "status":
		valid = valid && r.ID == "" && r.LeaseToken == "" && r.Outcome == "" &&
			r.Reason == "" && r.ObservedHash == "" && r.Successor == ""
	case "complete":
		valid = valid && isHex(r.ID, 64) && isHex(r.LeaseToken, 24) &&
			(r.Outcome == "fresh" || r.Outcome == "changed" || r.Outcome == "unavailable" || r.Outcome == "unsupported") &&
			r.Reason != "" && len(r.Reason) <= 128 &&
			strings.Trim(r.Reason, "abcdefghijklmnopqrstuvwxyz0123456789_-") == "" &&
			(r.ObservedHash == "" || isHex(r.ObservedHash, 64)) &&
			(r.Successor == "" || (r.Outcome == "changed" && isHex(r.Successor, 64)))
		if r.Outcome == "fresh" || r.Outcome == "changed" {
			valid = valid && isHex(r.ObservedHash, 64)
		}
	default:
		valid = false
	}
	if !valid {
		return errors.New("invalid evidence command")
	}
	return nil
}

func (s *Store) evidenceSource(ctx context.Context, node primitive.ObjectID, runID, hash string) (*IngestionRun, error) {
	match := bson.M{"node_id": node}
	if runID != "" {
		match["run_id"] = runID
	}
	runMatch := bson.M{"run.status": StatusCommitted}
	if hash != "" {
		runMatch["run.source_hash"] = hash
	}
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: match}},
		{{Key: "$lookup", Value: bson.M{"from": "ingestion_runs", "localField": "run_id", "foreignField": "run_id", "as": "run"}}},
		{{Key: "$unwind", Value: "$run"}},
		{{Key: "$match", Value: runMatch}},
		{{Key: "$sort", Value: bson.D{{Key: "run.created_at", Value: -1}, {Key: "run.run_id", Value: 1}}}},
	}
	discover := runID == "" && hash == ""
	if discover {
		pipeline = append(pipeline, bson.D{{Key: "$lookup", Value: bson.M{"from": "sources",
			"localField": "run.source_hash", "foreignField": "source_hash", "as": "source"}}})
	} else {
		pipeline = append(pipeline, bson.D{{Key: "$limit", Value: 1}})
	}
	cursor, err := s.db.Collection("run_node_links").Aggregate(ctx, pipeline,
		options.Aggregate().SetMaxTime(3*time.Second).SetBatchSize(1))
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var fallback *IngestionRun
	for cursor.Next(ctx) {
		var candidate struct {
			Run     IngestionRun `bson:"run"`
			Sources []Source     `bson:"source"`
		}
		if err = cursor.Decode(&candidate); err != nil {
			return nil, err
		}
		if fallback == nil {
			run := candidate.Run
			fallback = &run
		}
		if !discover {
			return &candidate.Run, nil
		}
		if len(candidate.Sources) != 0 &&
			evidenceHash(candidate.Sources[0].Content) == candidate.Run.SourceHash &&
			evidenceProfile(candidate.Sources[0], evidenceRow{SourceURL: candidate.Run.ExternalSourceID}) != "unsupported" {
			return &candidate.Run, nil
		}
	}
	return fallback, cursor.Err()
}

func (s *Store) evidenceCanonical(ctx context.Context, row evidenceRow) (bool, error) {
	var node KnowledgeNode
	err := s.db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"_id": row.NodeID}).Decode(&node)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if node.Status != StatusVerified || node.Sector == "personal" ||
		node.Sector != row.Sector || node.StableID != row.StableID ||
		node.Version != row.NodeVersion || evidenceHash(node.Content) != row.ContentHash {
		return false, nil
	}
	run, err := s.evidenceSource(ctx, row.NodeID, row.SourceRun, row.SourceHash)
	return run != nil && err == nil, err
}

func (s *Store) enrollEvidence(ctx context.Context, now int64) error {
	var state struct {
		After primitive.ObjectID `bson:"after"`
	}
	err := s.db.Collection("evidence_maintenance").FindOne(ctx, bson.M{"_id": "scan"}).Decode(&state)
	if err != nil && !errors.Is(err, mongo.ErrNoDocuments) {
		return err
	}
	filter := bson.M{"status": StatusVerified, "sector": bson.M{"$ne": "personal"}}
	if !state.After.IsZero() {
		filter["_id"] = bson.M{"$gt": state.After}
	}
	cursor, err := s.db.Collection("knowledge_nodes").Find(ctx, filter,
		options.Find().SetSort(bson.D{{Key: "_id", Value: 1}}).SetLimit(32))
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	var nodes []KnowledgeNode
	if err = cursor.All(ctx, &nodes); err != nil {
		return err
	}
	for _, node := range nodes {
		run, err := s.evidenceSource(ctx, node.ID, "", "")
		if err != nil {
			return err
		}
		if run == nil {
			continue
		}
		id := EvidenceBinding(node.ID.Hex(), node.Version, node.Content)
		row := evidenceRow{ID: id, NodeID: node.ID, NodeVersion: node.Version,
			ContentHash: evidenceHash(node.Content), StableID: node.StableID, Sector: node.Sector,
			SourceRun: run.RunID, SourceHash: run.SourceHash, SourceURL: run.ExternalSourceID,
			State: "pending", Profile: "unsupported", NextCheckMS: now, Reason: "awaiting_check"}
		if _, err = s.db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": id},
			bson.M{"$setOnInsert": row}, options.Update().SetUpsert(true)); err != nil {
			return err
		}
		var current evidenceRow
		if err = s.db.Collection("evidence_checks").FindOne(ctx, bson.M{"_id": id}).Decode(&current); err != nil {
			return err
		}
		canonical, err := s.evidenceCanonical(ctx, current)
		if err != nil {
			return err
		}
		idle := bson.M{"_id": id, "source_run": current.SourceRun, "source_hash": current.SourceHash,
			"source_url": current.SourceURL, "lease_until_ms": bson.M{"$lte": now}}
		if current.SourceHash != run.SourceHash || current.SourceURL != run.ExternalSourceID || !canonical {
			_, err = s.db.Collection("evidence_checks").UpdateOne(ctx, idle,
				bson.M{"$set": bson.M{"source_run": run.RunID, "source_hash": run.SourceHash,
					"source_url": run.ExternalSourceID, "state": "pending", "profile": "unsupported",
					"attempts": 0, "next_check_ms": now, "lease_until_ms": int64(0),
					"checked_at_ms": int64(0), "expires_at_ms": int64(0), "reason": "provenance_changed"},
					"$unset": bson.M{"lease_token": "", "last_token": "", "last_result": "", "maintenance_version": ""}})
		} else if current.State == "changed" && current.NextCheckMS > now+DocumentTTLMS {
			idle["next_check_ms"] = current.NextCheckMS
			_, err = s.db.Collection("evidence_checks").UpdateOne(ctx, idle,
				bson.M{"$set": bson.M{"next_check_ms": now}})
		}
		if err != nil {
			return err
		}
	}
	change := bson.M{"$unset": bson.M{"after": ""}}
	if len(nodes) != 0 {
		change = bson.M{"$set": bson.M{"after": nodes[len(nodes)-1].ID}}
	}
	_, err = s.db.Collection("evidence_maintenance").UpdateOne(ctx, bson.M{"_id": "scan"},
		change, options.Update().SetUpsert(true))
	return err
}

func evidenceProfile(source Source, row evidenceRow) string {
	if source.SourceType == "kernel_truth_observation" {
		var raw struct {
			Profile        string `json:"profile"`
			CheckerVersion string `json:"checker_version"`
			Observation    struct {
				Kind string `json:"kind"`
			} `json:"observation"`
		}
		if json.Unmarshal([]byte(source.Content), &raw) == nil &&
			raw.Profile == "truth-observation-v1" && raw.CheckerVersion == "1.0.0" {
			switch raw.Observation.Kind {
			case "document_quote_presence":
				return "document"
			case "host_probe_observation":
				return "host"
			}
		}
		return "unsupported"
	}
	if strings.HasPrefix(source.Content, "Windows host inventory\nclaim_class=host_fact\n") {
		return "host"
	}
	if strings.HasPrefix(row.SourceURL, "https://learn.microsoft.com/") ||
		strings.HasPrefix(row.SourceURL, "https://support.microsoft.com/") {
		return "document"
	}
	return "unsupported"
}

func (s *Store) EvidenceNext(ctx context.Context) (bson.M, error) {
	now := time.Now().UTC().UnixMilli()
	if _, err := s.db.Collection("evidence_maintenance").UpdateOne(ctx, bson.M{"_id": "policy"},
		bson.M{"$setOnInsert": bson.M{"version": EvidenceVersion}}, options.Update().SetUpsert(true)); err != nil {
		return nil, err
	}
	if _, err := s.evidenceRequired(ctx); err != nil {
		return nil, err
	}
	if _, err := s.db.Collection("evidence_checks").UpdateMany(ctx,
		bson.M{"lease_token": bson.M{"$exists": true}, "lease_until_ms": bson.M{"$lte": now},
			"attempts": bson.M{"$gte": EvidenceAttempts}},
		bson.M{"$set": bson.M{"state": "exception", "reason": "worker_interrupted",
			"next_check_ms": now + DocumentTTLMS, "lease_until_ms": int64(0)},
			"$unset": bson.M{"lease_token": ""}}); err != nil {
		return nil, err
	}
	if err := s.enrollEvidence(ctx, now); err != nil {
		return nil, err
	}
	_, err := s.db.Collection("evidence_checks").Indexes().CreateMany(ctx, []mongo.IndexModel{
		{Keys: bson.D{{Key: "next_check_ms", Value: 1}, {Key: "lease_until_ms", Value: 1}, {Key: "_id", Value: 1}},
			Options: options.Index().SetName("evidence_due")},
		{Keys: bson.D{{Key: "node_id", Value: 1}, {Key: "node_version", Value: 1}},
			Options: options.Index().SetName("evidence_origin")},
	})
	if err != nil {
		return nil, err
	}
	token := primitive.NewObjectID().Hex()
	var row evidenceRow
	filter := bson.M{"next_check_ms": bson.M{"$lte": now}, "lease_until_ms": bson.M{"$lte": now}}
	for _, supported := range []bool{true, false} {
		if supported {
			filter["profile"] = bson.M{"$in": []string{"host", "document"}}
		} else {
			delete(filter, "profile")
		}
		err = s.db.Collection("evidence_checks").FindOneAndUpdate(ctx, filter,
			bson.M{"$set": bson.M{"lease_token": token, "lease_until_ms": now + EvidenceLeaseMS},
				"$inc": bson.M{"attempts": 1}},
			options.FindOneAndUpdate().SetSort(bson.D{{Key: "next_check_ms", Value: 1}, {Key: "_id", Value: 1}}).
				SetReturnDocument(options.After)).Decode(&row)
		if !errors.Is(err, mongo.ErrNoDocuments) {
			break
		}
	}
	if errors.Is(err, mongo.ErrNoDocuments) {
		return bson.M{"status": "idle"}, nil
	}
	if err != nil {
		return nil, err
	}
	var source Source
	err = s.db.Collection("sources").FindOne(ctx, bson.M{"source_hash": row.SourceHash}).Decode(&source)
	if err != nil && !errors.Is(err, mongo.ErrNoDocuments) {
		return nil, err
	}
	row.Profile = evidenceProfile(source, row)
	canonical, err := s.evidenceCanonical(ctx, row)
	if err != nil {
		return nil, err
	}
	if _, err = s.db.Collection("evidence_checks").UpdateOne(ctx,
		bson.M{"_id": row.ID, "lease_token": token}, bson.M{"$set": bson.M{"profile": row.Profile}}); err != nil {
		return nil, err
	}
	bytes, err := json.Marshal(row)
	if err != nil {
		return nil, err
	}
	var job map[string]any
	if err = json.Unmarshal(bytes, &job); err != nil {
		return nil, err
	}
	job["raw_source"], job["source_type"] = source.Content, source.SourceType
	job["canonical"], job["source_valid"] = canonical, source.SourceHash != "" && evidenceHash(source.Content) == row.SourceHash
	return bson.M{"status": "leased", "job": job}, nil
}

func (s *Store) EvidenceComplete(ctx context.Context, request EvidenceRequest) (bson.M, error) {
	if err := ValidateEvidenceRequest(request); err != nil {
		return nil, err
	}
	var row evidenceRow
	if err := s.db.Collection("evidence_checks").FindOne(ctx, bson.M{"_id": request.ID}).Decode(&row); err != nil {
		return nil, err
	}
	now := time.Now().UTC().UnixMilli()
	result := evidenceResult{request.Outcome, request.Reason, request.ObservedHash, request.Successor}
	if row.LastToken == request.LeaseToken && reflect.DeepEqual(row.LastResult, result) {
		return bson.M{"status": "idempotent_noop", "id": request.ID, "state": row.State}, nil
	}
	canonical, err := s.evidenceCanonical(ctx, row)
	if err != nil {
		return nil, err
	}
	if row.LeaseToken != request.LeaseToken || row.LeaseUntilMS <= now ||
		((request.Outcome == "fresh" || request.Outcome == "changed") && !canonical) {
		return nil, errors.New("evidence lease expired or origin changed")
	}
	fresh := request.Outcome == "fresh"
	if fresh && ((row.Profile != "host" && row.Profile != "document") || request.ObservedHash != row.SourceHash) {
		return nil, errors.New("unsupported or mismatched evidence cannot be made fresh")
	}
	ttl := DocumentTTLMS
	if row.Profile == "host" {
		ttl = HostTTLMS
	}
	state, due, expires, attempts := "retry", now+EvidenceBackoff(row.Attempts), int64(0), row.Attempts
	switch {
	case fresh:
		state, due, expires, attempts = "fresh", now+ttl/2, now+ttl, 0
	case request.Outcome == "changed":
		state, due = "changed", now+DocumentTTLMS
	case row.Attempts >= EvidenceAttempts:
		state = "exception"
	}
	history := bson.M{"binding_id": row.ID, "node_id": row.NodeID, "node_version": row.NodeVersion,
		"content_hash": row.ContentHash, "source_hash": row.SourceHash, "source_run": row.SourceRun,
		"checked_at_ms": now, "profile": row.Profile, "maintenance_version": EvidenceVersion,
		"outcome": result.Outcome, "reason": result.Reason, "observed_hash": result.ObservedHash, "successor": result.Successor}
	if _, err = s.db.Collection("evidence_check_runs").UpdateOne(ctx,
		bson.M{"_id": request.LeaseToken}, bson.M{"$setOnInsert": history}, options.Update().SetUpsert(true)); err != nil {
		return nil, err
	}
	var saved bson.M
	if err = s.db.Collection("evidence_check_runs").FindOne(ctx, bson.M{"_id": request.LeaseToken}).Decode(&saved); err != nil {
		return nil, err
	}
	for key, value := range history {
		if key != "checked_at_ms" && !reflect.DeepEqual(saved[key], value) {
			return nil, errors.New("conflicting evidence result for the same lease")
		}
	}
	savedAt, ok := saved["checked_at_ms"].(int64)
	if !ok {
		return nil, errors.New("invalid retained evidence timestamp")
	}
	now = savedAt
	due = now + EvidenceBackoff(row.Attempts)
	if fresh {
		due, expires = now+ttl/2, now+ttl
	} else if request.Outcome == "changed" {
		due = now + DocumentTTLMS
	}
	if request.Successor != "" {
		if _, err = s.db.Collection("evidence_checks").UpdateMany(ctx,
			bson.M{"stable_id": request.Successor, "sector": row.Sector, "source_hash": request.ObservedHash,
				"state": bson.M{"$ne": "fresh"}, "lease_until_ms": bson.M{"$lte": time.Now().UTC().UnixMilli()}},
			bson.M{"$min": bson.M{"next_check_ms": time.Now().UTC().UnixMilli()}}); err != nil {
			return nil, err
		}
	}
	update := bson.M{"$set": bson.M{"state": state, "reason": request.Reason, "checked_at_ms": now,
		"expires_at_ms": expires, "next_check_ms": due, "lease_until_ms": int64(0), "attempts": attempts,
		"last_token": request.LeaseToken, "last_result": result, "maintenance_version": EvidenceVersion},
		"$unset": bson.M{"lease_token": ""}}
	filter := bson.M{"_id": row.ID, "lease_token": request.LeaseToken,
		"lease_until_ms": bson.M{"$gt": time.Now().UTC().UnixMilli()}}
	updated, err := s.db.Collection("evidence_checks").UpdateOne(ctx, filter, update)
	if err != nil {
		return nil, err
	}
	if updated.MatchedCount != 1 {
		return nil, errors.New("evidence result lost its lease")
	}
	return bson.M{"status": "recorded", "id": row.ID, "state": state, "expires_at_ms": expires,
		"next_check_ms": due, "attempts": attempts, "escalated": state == "exception"}, nil
}

func (s *Store) EvidenceCurrent(ctx context.Context, node primitive.ObjectID, version, content string) (bool, error) {
	required, err := s.evidenceRequired(ctx)
	if err != nil || !required {
		return !required && err == nil, err
	}
	var row evidenceRow
	err = s.db.Collection("evidence_checks").FindOne(ctx,
		bson.M{"_id": EvidenceBinding(node.Hex(), version, content)}).Decode(&row)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return false, nil
	}

	if err != nil {
		return false, err
	}
	if row.State != "fresh" || row.MaintenanceVersion != EvidenceVersion ||
		!EvidenceWindow(row.Profile, row.CheckedAtMS, row.ExpiresAtMS, time.Now().UTC().UnixMilli()) {
		return false, nil
	}
	filter := bson.M{"_id": row.LastToken, "binding_id": row.ID, "outcome": "fresh",
		"observed_hash": row.SourceHash,
		"checked_at_ms": row.CheckedAtMS, "content_hash": evidenceHash(content),
		"source_hash": row.SourceHash, "source_run": row.SourceRun, "node_version": version,
		"node_id": node, "profile": row.Profile, "maintenance_version": EvidenceVersion}
	err = s.db.Collection("evidence_check_runs").FindOne(ctx, filter).Err()
	if errors.Is(err, mongo.ErrNoDocuments) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return s.evidenceCanonical(ctx, row)
}

func (s *Store) evidenceRequired(ctx context.Context) (bool, error) {
	var policy struct {
		Version string `bson:"version"`
	}
	err := s.db.Collection("evidence_maintenance").FindOne(ctx, bson.M{"_id": "policy"}).Decode(&policy)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if policy.Version != EvidenceVersion {
		return false, errors.New("unsupported evidence maintenance policy")
	}
	return true, nil
}

func (s *Store) EvidenceCandidateStages(ctx context.Context) (mongo.Pipeline, error) {
	required, err := s.evidenceRequired(ctx)
	if err != nil || !required {
		return nil, err
	}
	now := time.Now().UTC().UnixMilli()
	window := func(profile string, ttl int64) bson.M {
		return bson.M{"$and": bson.A{
			bson.M{"$eq": bson.A{"$profile", profile}},
			bson.M{"$eq": bson.A{"$expires_at_ms", bson.M{"$add": bson.A{"$checked_at_ms", ttl}}}},
		}}
	}
	return mongo.Pipeline{
		{{Key: "$lookup", Value: bson.M{
			"from": "evidence_checks", "let": bson.M{"node": "$node_id", "version": "$node_version"},
			"pipeline": mongo.Pipeline{
				{{Key: "$match", Value: bson.M{
					"state": "fresh", "maintenance_version": EvidenceVersion,
					"checked_at_ms": bson.M{"$gt": int64(0), "$lte": now}, "expires_at_ms": bson.M{"$gt": now},
					"$expr": bson.M{"$and": bson.A{
						bson.M{"$eq": bson.A{"$node_id", "$$node"}},
						bson.M{"$eq": bson.A{"$node_version", "$$version"}},
						bson.M{"$or": bson.A{window("host", HostTTLMS), window("document", DocumentTTLMS)}},
					}},
				}}},
				{{Key: "$limit", Value: 1}},
			}, "as": "_current_evidence",
		}}},
		{{Key: "$match", Value: bson.M{"$or": bson.A{
			bson.M{"status": bson.M{"$ne": "verified"}}, bson.M{"sector": "personal"},
			bson.M{"_current_evidence.0": bson.M{"$exists": true}},
		}}}},
		{{Key: "$unset", Value: "_current_evidence"}},
	}, nil
}

func (s *Store) EvidenceStatus(ctx context.Context) (bson.M, error) {
	query := func(pipeline mongo.Pipeline) ([]bson.M, error) {
		cursor, err := s.db.Collection("evidence_checks").Aggregate(ctx, pipeline, options.Aggregate().SetMaxTime(3*time.Second))
		if err != nil {
			return nil, err
		}
		defer cursor.Close(ctx)
		rows := []bson.M{}
		if err = cursor.All(ctx, &rows); err != nil {
			return nil, err
		}
		return rows, nil
	}
	now := time.Now().UTC().UnixMilli()
	counts, err := query(mongo.Pipeline{
		{{Key: "$group", Value: bson.M{"_id": bson.M{"$cond": bson.A{
			bson.M{"$and": bson.A{bson.M{"$eq": bson.A{"$state", "fresh"}},
				bson.M{"$lte": bson.A{"$expires_at_ms", now}}}}, "expired", "$state"}},
			"count": bson.M{"$sum": 1}}}},
		{{Key: "$sort", Value: bson.D{{Key: "_id", Value: 1}}}},
	})
	if err != nil {
		return nil, err
	}
	incidents, err := query(mongo.Pipeline{
		{{Key: "$match", Value: bson.M{"state": "exception"}}},
		{{Key: "$group", Value: bson.M{"_id": bson.M{"reason": "$reason", "source": "$source_hash"},
			"count": bson.M{"$sum": 1}, "example": bson.M{"$min": "$stable_id"}}}},
		{{Key: "$sort", Value: bson.D{{Key: "count", Value: -1}, {Key: "_id", Value: 1}}}},
		{{Key: "$limit", Value: 8}},
	})
	if err != nil {
		return nil, err
	}
	enforced, err := s.evidenceRequired(ctx)
	if err != nil {
		return nil, err
	}
	return bson.M{"status": "ok", "enforced": enforced, "counts": counts, "incidents": incidents,
		"at_ms": now}, nil
}

func (s *Store) RunEvidence(ctx context.Context, request EvidenceRequest) (bson.M, error) {
	if err := ValidateEvidenceRequest(request); err != nil {
		return nil, err
	}
	switch request.Action {
	case "next":
		return s.EvidenceNext(ctx)
	case "complete":
		return s.EvidenceComplete(ctx, request)
	case "status":
		return s.EvidenceStatus(ctx)
	}
	return nil, fmt.Errorf("invalid evidence action %q", request.Action)
}

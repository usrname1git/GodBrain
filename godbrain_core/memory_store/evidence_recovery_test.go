package memorystore_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"testing"
	"time"

	store "godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type evidenceRecoveryFixture struct {
	t             *testing.T
	ctx           context.Context
	db            *mongo.Database
	lease, finish string
	sequence      int
}

func newEvidenceRecoveryFixture(t *testing.T, lease, finish string) *evidenceRecoveryFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(os.Getenv("MONGODB_TEST_URI")))
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	db := client.Database("godbrain_evidence_recovery_test_" + primitive.NewObjectID().Hex())
	t.Cleanup(func() {
		defer cancel()
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		if err := db.Drop(cleanup); err != nil {
			t.Error(err)
		}
		if err := client.Disconnect(cleanup); err != nil {
			t.Error(err)
		}
	})
	if err := store.EnsureIndexes(ctx, db); err != nil {
		t.Fatal(err)
	}
	return &evidenceRecoveryFixture{t: t, ctx: ctx, db: db, lease: lease, finish: finish}
}

func (f *evidenceRecoveryFixture) call(exe string, request store.EvidenceRequest, reject bool) map[string]any {
	f.t.Helper()
	input, err := json.Marshal(request)
	if err != nil {
		f.t.Fatal(err)
	}
	cmd := exec.CommandContext(f.ctx, exe)
	cmd.Env = append(os.Environ(), "MONGODB_URI="+os.Getenv("MONGODB_TEST_URI"), "MONGODB_DB_NAME="+f.db.Name())
	cmd.Stdin = bytes.NewReader(input)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	if reject != (err != nil) {
		f.t.Fatalf("reject=%v err=%v stdout=%s stderr=%s", reject, err, stdout.String(), stderr.String())
	}
	var result map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
		f.t.Fatal(err)
	}
	if reject && result["error"] == nil {
		f.t.Fatal("rejected completion omitted its error envelope")
	}
	return result
}

func (f *evidenceRecoveryFixture) node(raw, kind, url string) store.KnowledgeNode {
	f.t.Helper()
	node := store.KnowledgeNode{ID: primitive.NewObjectID(),
		StableID: proofHash("claim\x00windows-sre\x00" + raw), Version: "v1", Kind: "claim",
		Status: store.StatusVerified, Sector: "windows-sre", Content: raw,
		Confidence: 1, SchemaVersion: "1.0", CreatedAt: time.Now().Add(-2 * time.Hour)}
	if _, err := f.db.Collection("knowledge_nodes").InsertOne(f.ctx, node); err != nil {
		f.t.Fatal(err)
	}
	f.run(node, raw, kind, url)
	return node
}

func (f *evidenceRecoveryFixture) run(node store.KnowledgeNode, raw, kind, url string) {
	f.t.Helper()
	source := store.Source{ID: primitive.NewObjectID(), SourceType: kind,
		Content: raw, SourceHash: proofHash(raw), CreatedAt: time.Now().Add(-2 * time.Hour)}
	var existing store.Source
	err := f.db.Collection("sources").FindOne(f.ctx, bson.M{"source_hash": source.SourceHash}).Decode(&existing)
	if err == mongo.ErrNoDocuments {
		if _, err := f.db.Collection("sources").InsertOne(f.ctx, source); err != nil {
			f.t.Fatal(err)
		}
	} else if err != nil {
		f.t.Fatal(err)
	} else {
		source.ID = existing.ID
	}
	f.sequence++
	runID := primitive.NewObjectID().Hex()
	when := time.Now().Add(-time.Hour).Add(time.Duration(f.sequence) * time.Second)
	run := store.IngestionRun{RunID: runID, Status: store.StatusCommitted, SourceID: source.ID,
		SourceHash: source.SourceHash, Active: true, ExtractorID: "RecoveryFixture-" + runID,
		ExtractorVer: "1.0.0", SchemaVersion: "1.0", ExternalSourceID: url, CreatedAt: when, UpdatedAt: when}
	if _, err := f.db.Collection("ingestion_runs").InsertOne(f.ctx, run); err != nil {
		f.t.Fatal(err)
	}
	if _, err := f.db.Collection("run_node_links").InsertOne(f.ctx, store.RunNodeLink{
		RunID: runID, NodeID: node.ID, StableID: node.StableID, NodeVersion: node.Version, CreatedAt: when,
	}); err != nil {
		f.t.Fatal(err)
	}
}

func (f *evidenceRecoveryFixture) update(node store.KnowledgeNode, fields bson.M) {
	f.t.Helper()
	if _, err := f.db.Collection("evidence_checks").UpdateOne(f.ctx,
		bson.M{"_id": store.EvidenceBinding(node.ID.Hex(), node.Version, node.Content)},
		bson.M{"$set": fields}); err != nil {
		f.t.Fatal(err)
	}
}

func (f *evidenceRecoveryFixture) next() map[string]any {
	f.t.Helper()
	if _, err := f.db.Collection("evidence_maintenance").UpdateOne(f.ctx, bson.M{"_id": "scan"},
		bson.M{"$unset": bson.M{"after": ""}}); err != nil {
		f.t.Fatal(err)
	}
	return f.call(f.lease, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
}

func (f *evidenceRecoveryFixture) result(job map[string]any, outcome, hash, successor string) store.EvidenceRequest {
	return store.EvidenceRequest{Command: "evidence", Action: "complete",
		ID: job["_id"].(string), LeaseToken: job["lease_token"].(string), Outcome: outcome,
		Reason: "recovery_fixture", ObservedHash: hash, Successor: successor}
}

func (f *evidenceRecoveryFixture) current(node store.KnowledgeNode, want bool) {
	f.t.Helper()
	current, err := store.NewStore(f.db).EvidenceCurrent(f.ctx, node.ID, node.Version, node.Content)
	if err != nil || current != want {
		f.t.Fatalf("current=%v want=%v err=%v", current, want, err)
	}
}

func TestEvidenceRecovery(t *testing.T) {
	cpp, rollback := os.Getenv("GODBRAIN_CPP_STORE_TEST_EXE"), os.Getenv("GODBRAIN_GO_STORE_TEST_EXE")
	if os.Getenv("MONGODB_TEST_URI") == "" || cpp == "" || rollback == "" {
		t.Skip("disposable MongoDB and source-built native/Go executables required")
	}
	const url = "https://learn.microsoft.com/en-us/windows/recovery-fixture"
	for _, order := range []struct{ name, lease, finish string }{
		{"native-leases-go-completes", cpp, rollback}, {"go-leases-native-completes", rollback, cpp},
	} {
		t.Run(order.name, func(t *testing.T) {
			for _, profile := range []string{"host", "document"} {
				t.Run(profile+"-renewal-before-unsupported-backlog", func(t *testing.T) {
					f := newEvidenceRecoveryFixture(t, order.lease, order.finish)
					raw, kind, origin := "Synthetic supported document.", "web_document", url
					if profile == "host" {
						raw, kind, origin = "Windows host inventory\nclaim_class=host_fact\nfixture=host", "operator_thought", "host:fixture"
					}
					node := f.node(raw, kind, origin)
					job := f.next()["job"].(map[string]any)
					f.call(f.finish, f.result(job, "fresh", proofHash(raw), ""), false)
					backlog := f.node("Synthetic unsupported history.", "session_transcript", "session:backlog")
					job = f.next()["job"].(map[string]any)
					f.call(f.finish, f.result(job, "unsupported", "", ""), false)
					f.update(backlog, bson.M{"next_check_ms": int64(0)})
					f.update(node, bson.M{"next_check_ms": time.Now().UnixMilli() - 1})
					job = f.next()["job"].(map[string]any)
					if job["stable_id"] != node.StableID {
						t.Fatal("an older unsupported retry displaced a due supported renewal")
					}
					waiting := f.next()["job"].(map[string]any)
					if waiting["stable_id"] != backlog.StableID {
						t.Fatal("unsupported recovery stopped when no supported renewal was due")
					}
					f.call(f.finish, f.result(waiting, "unsupported", "", ""), false)
					if f.next()["status"] != "idle" {
						t.Fatal("priority stole an active renewal lease or bypassed a retry deadline")
					}
					f.call(f.finish, f.result(job, "fresh", proofHash(raw), ""), false)
					f.current(node, true)
					if f.next()["status"] != "idle" {
						t.Fatal("priority bypassed a retry deadline or leased a future renewal")
					}
				})
			}
			t.Run("returning-observation-and-retired-deadline", func(t *testing.T) {
				f := newEvidenceRecoveryFixture(t, order.lease, order.finish)
				a := f.node("Synthetic exact state A.", "web_document", url)
				job := f.next()["job"].(map[string]any)
				hashA := job["source_hash"].(string)
				f.call(f.finish, f.result(job, "fresh", hashA, ""), false)
				b := f.node("Synthetic exact state B.", "web_document", url)
				hashB := proofHash(b.Content)
				f.update(a, bson.M{"next_check_ms": int64(0)})
				job = f.next()["job"].(map[string]any)
				retired := f.call(f.finish, f.result(job, "changed", hashB, b.StableID), false)
				if retired["next_check_ms"].(float64) > float64(time.Now().UnixMilli()+store.DocumentTTLMS) {
					t.Fatal("superseded observation lost bounded recovery")
				}
				job = f.next()["job"].(map[string]any)
				f.call(f.finish, f.result(job, "fresh", hashB, ""), false)
				f.update(b, bson.M{"next_check_ms": int64(0)})
				job = f.next()["job"].(map[string]any)
				back := f.result(job, "changed", hashA, a.StableID)
				f.call(f.finish, back, false)
				job = f.next()["job"].(map[string]any)
				if job["stable_id"] != a.StableID {
					t.Fatal("returning observation was not re-armed")
				}
				f.current(a, false)
				f.call(f.finish, f.result(job, "fresh", hashA, ""), false)
				f.current(a, true)
				f.call(f.lease, back, false)
				f.current(a, true)
				f.update(a, bson.M{"state": "changed", "expires_at_ms": int64(0),
					"next_check_ms": int64(^uint64(0)>>1) / 2})
				job = f.next()["job"].(map[string]any)
				if job["stable_id"] != a.StableID {
					t.Fatal("previously retired deadline was not repaired")
				}
			})
			t.Run("supported-source-before-newest-limit", func(t *testing.T) {
				f := newEvidenceRecoveryFixture(t, order.lease, order.finish)
				node := f.node("Synthetic supported primary observation.", "web_document", url)
				for i := 0; i < 40; i++ {
					f.run(node, fmt.Sprintf("Transcript %d repeats %s", i, node.Content), "session_transcript", "session:repeat")
				}
				f.run(node, `{"profile":123,"checker_version":"1.0.0","observation":{"kind":"host_probe_observation"}}`,
					"kernel_truth_observation", "truth:malformed")
				job := f.next()["job"].(map[string]any)
				if job["profile"] != "document" || job["source_hash"] != proofHash(node.Content) {
					t.Fatal("newer unsupported provenance masked a valid older source")
				}
				f.call(f.finish, f.result(job, "fresh", proofHash(node.Content), ""), false)
				f.run(node, node.Content, "web_document", url)
				if f.next()["status"] != "idle" {
					t.Fatal("equivalent newer run invalidated a usable proof")
				}
				f.current(node, true)
			})
			t.Run("active-lease-and-stale-worker", func(t *testing.T) {
				f := newEvidenceRecoveryFixture(t, order.lease, order.finish)
				node := f.node("Synthetic initially unsupported finding.", "session_transcript", "session:original")
				old := f.next()["job"].(map[string]any)
				if old["profile"] != "unsupported" {
					t.Fatal("initial source unexpectedly supported")
				}
				raw := node.Content + " Primary source context."
				f.run(node, raw, "web_document", url)
				if f.next()["status"] != "idle" {
					t.Fatal("source reconciliation stole an active lease")
				}
				f.update(node, bson.M{"lease_until_ms": int64(1), "next_check_ms": int64(0)})
				job := f.next()["job"].(map[string]any)
				if job["source_hash"] != proofHash(raw) || job["profile"] != "document" {
					t.Fatal("expired unsupported binding did not reconcile")
				}
				f.call(f.finish, f.result(old, "unsupported", "", ""), true)
				f.current(node, false)
				f.call(f.finish, f.result(job, "fresh", proofHash(raw), ""), false)
				f.current(node, true)
			})
			t.Run("rebound-proofs-are-invalidated-not-rewritten", func(t *testing.T) {
				f := newEvidenceRecoveryFixture(t, order.lease, order.finish)
				node := f.node("Synthetic exact original primary source.", "web_document", url)
				job := f.next()["job"].(map[string]any)
				old := f.result(job, "fresh", proofHash(node.Content), "")
				f.call(f.finish, old, false)
				var before, after bson.M
				if err := f.db.Collection("evidence_check_runs").FindOne(f.ctx, bson.M{"_id": old.LeaseToken}).Decode(&before); err != nil {
					t.Fatal(err)
				}
				raw := node.Content + " New primary context."
				f.run(node, raw, "web_document", url)
				job = f.next()["job"].(map[string]any)
				f.current(node, false)
				f.call(f.finish, old, true)
				if err := f.db.Collection("evidence_check_runs").FindOne(f.ctx, bson.M{"_id": old.LeaseToken}).Decode(&after); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(before, after) || job["source_hash"] != proofHash(raw) {
					t.Fatal("reconciliation rewrote history or retained the old source")
				}
				f.call(f.finish, f.result(job, "fresh", proofHash(raw), ""), false)
				f.current(node, true)
			})
		})
	}
}

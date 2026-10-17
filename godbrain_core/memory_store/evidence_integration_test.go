package memorystore_test

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	store "godbrain_core/memory_store"
	"godbrain_core/memory_store/rag"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

func proofHash(content string) string {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(content))
	return hex.EncodeToString(hash.Sum(nil))
}

func TestEvidenceCrossBackendMaintenance(t *testing.T) {
	uri := os.Getenv("MONGODB_TEST_URI")
	cpp, rollback := os.Getenv("GODBRAIN_CPP_STORE_TEST_EXE"), os.Getenv("GODBRAIN_GO_STORE_TEST_EXE")
	if uri == "" || cpp == "" || rollback == "" {
		t.Skip("disposable MONGODB_TEST_URI and both source-built test executables required")
	}
	for _, name := range []string{"GODBRAIN_EMBEDDING_ENDPOINT", "GODBRAIN_EMBEDDING_MODEL",
		"GODBRAIN_EMBEDDING_MODEL_REVISION", "GODBRAIN_EMBEDDING_MODEL_SHA256",
		"GODBRAIN_EMBEDDING_DIMENSION", "GODBRAIN_RAG_EMBEDDING_REQUIRED"} {
		t.Setenv(name, "")
	}
	for _, order := range []struct{ name, first, second string }{
		{"native-leases-go-completes", cpp, rollback},
		{"go-leases-native-completes", rollback, cpp},
	} {
		t.Run(order.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
			if err != nil {
				t.Fatal(err)
			}
			db := client.Database("godbrain_evidence_test_" + primitive.NewObjectID().Hex())
			t.Cleanup(func() {
				cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
				defer done()
				if err := db.Drop(cleanup); err != nil {
					t.Error(err)
				}
				if err := client.Disconnect(cleanup); err != nil {
					t.Error(err)
				}
			})
			if err = store.EnsureIndexes(ctx, db); err != nil {
				t.Fatal(err)
			}
			if err = rag.EnsureIndexes(ctx, db); err != nil {
				t.Fatal(err)
			}
			call := func(exe string, request any, reject bool) map[string]any {
				t.Helper()
				input, err := json.Marshal(request)
				if err != nil {
					t.Fatal(err)
				}
				if raw, ok := request.(string); ok {
					input = []byte(raw)
				}
				cmd := exec.CommandContext(ctx, exe)
				cmd.Env = append(os.Environ(), "MONGODB_URI="+uri, "MONGODB_DB_NAME="+db.Name())
				cmd.Stdin = bytes.NewReader(input)
				var stdout, stderr bytes.Buffer
				cmd.Stdout, cmd.Stderr = &stdout, &stderr
				err = cmd.Run()
				if reject != (err != nil) {
					t.Fatalf("%s: reject=%v err=%v stdout=%s stderr=%s", filepath.Base(exe), reject, err, stdout.String(), stderr.String())
				}
				var receipt map[string]any
				decoder := json.NewDecoder(&stdout)
				if err := decoder.Decode(&receipt); err != nil {
					t.Fatal(err)
				}
				if reject && receipt["error"] == nil {
					t.Fatal("failure had no error envelope")
				}
				return receipt
			}
			now := time.Now().UTC()
			source := store.Source{ID: primitive.NewObjectID(), SourceType: "web_document",
				Content: "Exact synthetic primary evidence with  two spaces and Unicode Å.", CreatedAt: now}
			source.SourceHash = proofHash(source.Content)
			node := store.KnowledgeNode{ID: primitive.NewObjectID(), StableID: strings.Repeat("a", 64),
				Version: "v1", Kind: "claim", Status: "verified", Sector: "windows-sre",
				Content: "Synthetic current component store evidence.", Confidence: 1, SchemaVersion: "1.0", CreatedAt: now}
			run := store.IngestionRun{RunID: primitive.NewObjectID().Hex(), Status: store.StatusCommitted,
				SourceHash: source.SourceHash, SourceID: source.ID, Active: true, ExtractorID: "Fixture",
				ExtractorVer: "1.0.0", SchemaVersion: "1.0", CreatedAt: now, UpdatedAt: now,
				ExternalSourceID: "https://learn.microsoft.com/en-us/windows/test-fixture"}
			for collection, document := range map[string]any{
				"sources": source, "knowledge_nodes": node, "ingestion_runs": run,
				"run_node_links": store.RunNodeLink{RunID: run.RunID, NodeID: node.ID,
					StableID: node.StableID, NodeVersion: node.Version, CreatedAt: now},
			} {
				if _, err := db.Collection(collection).InsertOne(ctx, document); err != nil {
					t.Fatal(err)
				}
			}
			projector := rag.NewProjector(db)
			if err = projector.ProjectCommittedRun(ctx, run.RunID); err != nil {
				t.Fatal(err)
			}
			engine := rag.NewEngine(db, rag.Config{})
			checkReads := func(want bool) {
				t.Helper()
				current, err := store.NewStore(db).EvidenceCurrent(ctx, node.ID, node.Version, node.Content)
				if err != nil || current != want {
					t.Fatalf("Go admission current=%v want=%v err=%v", current, want, err)
				}
				response, err := engine.Search(ctx, rag.SearchRequest{Query: "component store", Status: "verified", RetrievalMode: "lexical"})
				if err != nil || (len(response.Results) > 0) != want {
					t.Fatalf("Go search=%+v want=%v err=%v", response.Results, want, err)
				}
				document, err := engine.Document(ctx, node.ID.Hex())
				if err != nil || (document.Status == "verified") != want {
					t.Fatalf("Go document=%+v err=%v", document, err)
				}
				graph, err := engine.Graph(ctx, 10)
				if err != nil || len(graph.Nodes) != 1 || (graph.Nodes[0].Status == "verified") != want {
					t.Fatalf("Go graph=%+v err=%v", graph, err)
				}
			}
			checkReads(true) // Before the authenticated maintenance cutover, preserve the earlier contract.
			job := call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)["job"].(map[string]any)
			if job["_id"] != store.EvidenceBinding(node.ID.Hex(), node.Version, node.Content) ||
				job["profile"] != "document" || job["source_valid"] != true || job["raw_source"] != source.Content {
				t.Fatalf("lease did not bind the exact canonical source: %+v", job)
			}
			checkReads(false)
			result := store.EvidenceRequest{Command: "evidence", Action: "complete", ID: job["_id"].(string),
				LeaseToken: job["lease_token"].(string), Outcome: "fresh", Reason: "exact_source_unchanged", ObservedHash: source.SourceHash}
			bad := result
			bad.ObservedHash = strings.Repeat("0", 64)
			call(order.second, bad, true)
			first := call(order.second, result, false)
			if first["state"] != "fresh" {
				t.Fatal(first)
			}
			checkReads(true)
			again := call(order.first, result, false)
			if again["status"] != "idempotent_noop" {
				t.Fatal("retry extended a completed proof")
			}
			count, err := db.Collection("evidence_check_runs").CountDocuments(ctx, bson.M{})
			if err != nil || count != 1 {
				t.Fatalf("duplicate proof records: count=%d err=%v", count, err)
			}
			for _, exe := range []string{cpp, rollback} {
				for _, input := range []string{
					`{"command":"evidence","action":"next","id":null}`,
					`{"command":"evidence","action":"next","ttl":999999}`,
					`{"command":"evidence","action":"next"} {}`,
					`{"command":"evidence","action":"next","action":"status"}`,
					`{"command":"evidence","action":"next","Action":"status"}`,
					`{"command":"evidence","action":"next","a\u0063tion":"status"}`,
				} {
					call(exe, input, true)
				}
			}
			if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
				bson.M{"$set": bson.M{"expires_at_ms": time.Now().Add(-time.Second).UnixMilli(), "next_check_ms": int64(0)}}); err != nil {
				t.Fatal(err)
			}
			checkReads(false)
			job = call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)["job"].(map[string]any)
			old := result
			result.LeaseToken = job["lease_token"].(string)
			call(order.second, old, false) // Old delivery is a no-op, never a renewal of the newer lease.
			if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
				bson.M{"$set": bson.M{"lease_until_ms": int64(1), "next_check_ms": int64(0)}}); err != nil {
				t.Fatal(err)
			}
			call(order.second, result, true)
			job = call(order.second, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)["job"].(map[string]any)
			result.LeaseToken = job["lease_token"].(string)
			call(order.first, result, false)
			checkReads(true)
			if _, err = db.Collection("ingestion_runs").UpdateOne(ctx, bson.M{"run_id": run.RunID},
				bson.M{"$set": bson.M{"status": store.StatusFailed}}); err != nil {
				t.Fatal(err)
			}
			checkReads(false)
			if _, err = db.Collection("ingestion_runs").UpdateOne(ctx, bson.M{"run_id": run.RunID},
				bson.M{"$set": bson.M{"status": store.StatusCommitted}}); err != nil {
				t.Fatal(err)
			}
			checkReads(true)
			testNativeEvidenceReads(t, ctx, cpp, uri, db.Name(), node.ID.Hex(), true)
			if _, err = db.Collection("evidence_check_runs").UpdateOne(ctx, bson.M{"_id": result.LeaseToken},
				bson.M{"$set": bson.M{"observed_hash": strings.Repeat("0", 64)}}); err != nil {
				t.Fatal(err)
			}
			checkReads(false)
			testNativeEvidenceReads(t, ctx, cpp, uri, db.Name(), node.ID.Hex(), false)
			if _, err = db.Collection("evidence_check_runs").UpdateOne(ctx, bson.M{"_id": result.LeaseToken},
				bson.M{"$set": bson.M{"observed_hash": source.SourceHash}}); err != nil {
				t.Fatal(err)
			}
			if _, err = db.Collection("evidence_check_runs").DeleteOne(ctx, bson.M{"_id": result.LeaseToken}); err != nil {
				t.Fatal(err)
			}
			checkReads(false)
			testNativeEvidenceReads(t, ctx, cpp, uri, db.Name(), node.ID.Hex(), false)

			unmanaged := run
			unmanaged.ID = primitive.NilObjectID
			unmanaged.RunID = primitive.NewObjectID().Hex()
			unmanaged.ExtractorID = "UnmanagedFixture"
			unmanaged.ExternalSourceID = "session-fixture"
			if _, err = db.Collection("ingestion_runs").InsertOne(ctx, unmanaged); err != nil {
				t.Fatal(err)
			}
			for index := 0; index < 2; index++ {
				unmanagedNode := node
				unmanagedNode.ID = primitive.NewObjectID()
				unmanagedNode.StableID = strings.Repeat(strconv.Itoa(index+2), 64)
				unmanagedNode.Content = "Previously judged legacy fixture " + strconv.Itoa(index)
				if _, err = db.Collection("knowledge_nodes").InsertOne(ctx, unmanagedNode); err != nil {
					t.Fatal(err)
				}
				if _, err = db.Collection("run_node_links").InsertOne(ctx, store.RunNodeLink{
					RunID: unmanaged.RunID, NodeID: unmanagedNode.ID, StableID: unmanagedNode.StableID,
					NodeVersion: unmanagedNode.Version, CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			for checkedNode := 0; checkedNode < 2; checkedNode++ {
				var unsupportedID string
				for attempt := 1; attempt <= store.EvidenceAttempts; attempt++ {
					if unsupportedID != "" {
						if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": unsupportedID},
							bson.M{"$set": bson.M{"next_check_ms": int64(0)}}); err != nil {
							t.Fatal(err)
						}
					}
					next := call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
					if next["status"] == "idle" {
						next = call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
					}
					unmanagedJob := next["job"].(map[string]any)
					unsupportedID = unmanagedJob["_id"].(string)
					if unmanagedJob["profile"] != "unsupported" {
						t.Fatal("legacy source guessed a checker")
					}
					failure := store.EvidenceRequest{Command: "evidence", Action: "complete", ID: unsupportedID,
						LeaseToken: unmanagedJob["lease_token"].(string), Outcome: "unsupported", Reason: "no_reproducible_source"}
					if attempt == 1 {
						forged := failure
						forged.Outcome = "fresh"
						forged.ObservedHash = source.SourceHash
						call(order.second, forged, true)
					}
					receipt := call(order.second, failure, false)
					wantState := "retry"
					if attempt == store.EvidenceAttempts {
						wantState = "exception"
					}
					if receipt["state"] != wantState || receipt["attempts"] != float64(attempt) ||
						receipt["escalated"] != (attempt == store.EvidenceAttempts) {
						t.Fatalf("bounded recovery: %+v", receipt)
					}
				}
			}
			if err = projector.ProjectCommittedRun(ctx, unmanaged.RunID); err != nil {
				t.Fatal(err)
			}
			for _, exe := range []string{cpp, rollback} {
				summary := call(exe, store.EvidenceRequest{Command: "evidence", Action: "status"}, false)
				incidents := summary["incidents"].([]any)
				if len(incidents) != 1 || incidents[0].(map[string]any)["count"] != float64(2) {
					t.Fatalf("operator incidents were not deduplicated by failure/source: %+v", summary)
				}
			}

			if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
				bson.M{"$set": bson.M{"next_check_ms": int64(0), "lease_until_ms": int64(0)}}); err != nil {
				t.Fatal(err)
			}
			var mu sync.Mutex
			statuses := []string{}
			var wg sync.WaitGroup
			for _, exe := range []string{cpp, rollback} {
				wg.Add(1)
				go func(exe string) {
					defer wg.Done()
					receipt := call(exe, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
					mu.Lock()
					statuses = append(statuses, receipt["status"].(string))
					mu.Unlock()
				}(exe)
			}
			wg.Wait()
			if len(statuses) != 2 || statuses[0] == statuses[1] {
				t.Fatalf("competing workers both got the same lease: %v", statuses)
			}
			var active struct {
				LeaseToken string `bson:"lease_token"`
			}
			if err = db.Collection("evidence_checks").FindOne(ctx, bson.M{"_id": result.ID}).Decode(&active); err != nil {
				t.Fatal(err)
			}
			result.LeaseToken = active.LeaseToken
			call(order.second, result, false)
			for attempt := 1; attempt <= store.EvidenceAttempts; attempt++ {
				if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
					bson.M{"$set": bson.M{"next_check_ms": int64(0), "lease_until_ms": int64(0)}}); err != nil {
					t.Fatal(err)
				}
				crashed := call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)["job"].(map[string]any)
				if crashed["_id"] != result.ID || crashed["attempts"] != float64(attempt) {
					t.Fatalf("interrupted worker lost its attempt count: %+v", crashed)
				}
			}
			if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
				bson.M{"$set": bson.M{"lease_until_ms": int64(0)}}); err != nil {
				t.Fatal(err)
			}
			call(order.second, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
			var interrupted bson.M
			if err = db.Collection("evidence_checks").FindOne(ctx, bson.M{"_id": result.ID}).Decode(&interrupted); err != nil {
				t.Fatal(err)
			}
			if interrupted["state"] != "exception" || interrupted["reason"] != "worker_interrupted" ||
				interrupted["lease_token"] != nil {
				t.Fatalf("repeated crashes did not become a recoverable incident: %+v", interrupted)
			}
			due := interrupted["next_check_ms"]
			call(order.first, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)
			if err = db.Collection("evidence_checks").FindOne(ctx, bson.M{"_id": result.ID}).Decode(&interrupted); err != nil {
				t.Fatal(err)
			}
			if interrupted["next_check_ms"] != due {
				t.Fatal("idle ticks kept postponing interrupted-worker recovery")
			}
			if _, err = db.Collection("evidence_checks").UpdateOne(ctx, bson.M{"_id": result.ID},
				bson.M{"$set": bson.M{"next_check_ms": int64(0)}}); err != nil {
				t.Fatal(err)
			}
			recovered := call(order.second, store.EvidenceRequest{Command: "evidence", Action: "next"}, false)["job"].(map[string]any)
			result.LeaseToken = recovered["lease_token"].(string)
			if recovery := call(order.first, result, false); recovery["state"] != "fresh" || recovery["attempts"] != float64(0) {
				t.Fatalf("incident could not recover without operator judgment: %+v", recovery)
			}
			for index := 0; index < 256; index++ {
				obsolete := node
				obsolete.ID = primitive.NewObjectID()
				obsolete.StableID = fmt.Sprintf("%064d", index+10000)
				obsolete.Content = "component store"
				if _, err = db.Collection("knowledge_nodes").InsertOne(ctx, obsolete); err != nil {
					t.Fatal(err)
				}
				if _, err = db.Collection("run_node_links").InsertOne(ctx, store.RunNodeLink{
					RunID: run.RunID, NodeID: obsolete.ID, StableID: obsolete.StableID,
					NodeVersion: obsolete.Version, CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			if err = projector.ProjectCommittedRun(ctx, run.RunID); err != nil {
				t.Fatal(err)
			}
			current, err := engine.Search(ctx, rag.SearchRequest{Query: "component store",
				Status: "verified", RetrievalMode: "lexical"})
			if err != nil || len(current.Results) != 1 || current.Results[0].NodeID != node.ID.Hex() {
				t.Fatalf("obsolete high-score records crowded out current evidence: %+v err=%v", current, err)
			}
			testNativeEvidenceReads(t, ctx, cpp, uri, db.Name(), node.ID.Hex(), true)
		})
	}
}

func testNativeEvidenceReads(t *testing.T, ctx context.Context, cpp, uri, database, node string, want bool) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	cmd := exec.CommandContext(ctx, filepath.Join(filepath.Dir(cpp), "rag-service.exe"))
	cmd.Env = append(os.Environ(), "MONGODB_URI="+uri, "MONGODB_DB_NAME="+database, "GODBRAIN_RAG_PORT="+strconv.Itoa(port))
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	client := &http.Client{Timeout: 2 * time.Second}
	ready := false
	lastHealth := ""
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		res, err := client.Get(base + "/health")
		if err == nil {
			body, readErr := io.ReadAll(io.LimitReader(res.Body, 65536))
			lastHealth = fmt.Sprintf("HTTP %d: %s (read=%v)", res.StatusCode, body, readErr)
			res.Body.Close()
			if res.StatusCode == 200 && readErr == nil {
				ready = true
				break
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	if !ready {
		t.Fatalf("native fixture server was not ready: %s; %s", output.String(), lastHealth)
	}
	res, err := client.Get(base + "/v1/document?id=" + node)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var document map[string]any
	if err = json.NewDecoder(res.Body).Decode(&document); err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != 200 || (document["status"] == "verified") != want {
		t.Fatalf("native canonical admission: %v status=%d want=%v", document, res.StatusCode, want)
	}
	response, err := client.Post(base+"/v1/search", "application/json",
		strings.NewReader(`{"query":"component store","status":"verified","retrieval_mode":"lexical"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var search rag.SearchResponse
	if err = json.NewDecoder(response.Body).Decode(&search); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || (len(search.Results) > 0) != want {
		t.Fatalf("native search admission: status=%d results=%+v want=%v", response.StatusCode, search.Results, want)
	}
}

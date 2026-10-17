package memorystore_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	store "godbrain_core/memory_store"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func TestResearchRelationEncodingParity(t *testing.T) {
	uri, fixture := os.Getenv("MONGODB_TEST_URI"), os.Getenv("GODBRAIN_RESEARCH_RELATION_FIXTURE")
	cpp, rollback := os.Getenv("GODBRAIN_CPP_STORE_TEST_EXE"), os.Getenv("GODBRAIN_GO_STORE_TEST_EXE")
	if uri == "" || fixture == "" || cpp == "" || rollback == "" {
		t.Skip("disposable MongoDB, source-built stores and native --relation-document fixture required")
	}
	for _, name := range []string{"GODBRAIN_EMBEDDING_ENDPOINT", "GODBRAIN_EMBEDDING_MODEL",
		"GODBRAIN_EMBEDDING_MODEL_REVISION", "GODBRAIN_EMBEDDING_MODEL_SHA256",
		"GODBRAIN_EMBEDDING_DIMENSION", "GODBRAIN_RAG_EMBEDDING_REQUIRED"} {
		t.Setenv(name, "")
	}
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	var fixed, legacy map[string]any
	if err := json.Unmarshal(data, &fixed); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &legacy); err != nil {
		t.Fatal(err)
	}
	var raw struct {
		Relation map[string]any `json:"relation"`
	}
	if err := json.Unmarshal([]byte(fixed["raw_transcript"].(string)), &raw); err != nil {
		t.Fatal(err)
	}
	relation, err := json.Marshal(raw.Relation)
	if err != nil {
		t.Fatal(err)
	}
	claim := legacy["payload"].(map[string]any)["claims"].([]any)[0].(map[string]any)
	content := claim["content"].(string)
	marker := strings.Index(content, "relation=")
	if marker < 0 || fixed["extractor_version"] != "1.0.1" ||
		!strings.Contains(raw.Relation["quote"].(string), "\u00a0") ||
		!strings.Contains(raw.Relation["quote"].(string), "\u2003") {
		t.Fatal("fixture does not exercise the changed Unicode relation encoding")
	}
	claim["content"] = content[:marker+9] + string(relation) + "\n"
	legacy["extractor_version"] = "1.0.0"
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		if err := client.Disconnect(cleanup); err != nil {
			t.Error(err)
		}
	})
	if err := client.Ping(ctx, nil); err != nil {
		t.Fatal(err)
	}
	type receipt struct {
		Status   string `json:"status"`
		StableID string `json:"-"`
		RunID    string `json:"run_id"`
	}
	identities := map[string][]string{}
	for _, backend := range []struct{ name, exe string }{{"native", cpp}, {"go", rollback}} {
		db := client.Database("godbrain_research_relation_test_" + primitive.NewObjectID().Hex())
		t.Cleanup(func() {
			cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
			defer done()
			if err := db.Drop(cleanup); err != nil {
				t.Error(err)
			}
		})
		ingest := func(document map[string]any) receipt {
			t.Helper()
			input, err := json.Marshal(document)
			if err != nil {
				t.Fatal(err)
			}
			cmd := exec.CommandContext(ctx, backend.exe)
			cmd.Env = append(os.Environ(), "MONGODB_URI="+uri, "MONGODB_DB_NAME="+db.Name())
			cmd.Stdin = bytes.NewReader(input)
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			if err := cmd.Run(); err != nil {
				t.Fatalf("%s ingestion: %v stdout=%s stderr=%s", backend.name, err, stdout.String(), stderr.String())
			}
			var result receipt
			if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if (result.Status != "committed" && result.Status != "idempotent_noop") || result.RunID == "" {
				t.Fatalf("missing committed candidate receipt: %s", stdout.String())
			}
			var link struct {
				StableID string `bson:"stable_id"`
			}
			if err := db.Collection("run_node_links").FindOne(ctx, bson.M{"run_id": result.RunID}).Decode(&link); err != nil {
				t.Fatal(err)
			}
			if len(link.StableID) != 64 {
				t.Fatal("committed run has no stable candidate identity")
			}
			result.StableID = link.StableID
			return result
		}
		old, current := ingest(legacy), ingest(fixed)
		again := ingest(fixed)
		if old.Status != "committed" || current.Status != "committed" ||
			old.RunID == current.RunID || again.RunID != current.RunID ||
			again.Status != "idempotent_noop" || again.StableID != current.StableID {
			t.Fatal("changed rendering reused an old run or lost idempotency")
		}
		var node store.KnowledgeNode
		if err := db.Collection("knowledge_nodes").FindOne(ctx, bson.M{"stable_id": current.StableID}).Decode(&node); err != nil {
			t.Fatal(err)
		}
		var restored map[string]any
		marker = strings.Index(node.Content, "relation=")
		if marker < 0 {
			t.Fatal("stored relation marker was lost")
		}
		if err := json.Unmarshal([]byte(node.Content[marker+9:]), &restored); err != nil {
			t.Fatal(err)
		}
		if restored["quote"] != raw.Relation["quote"] || node.Status != "candidate" {
			t.Fatal("stored quote changed or relation acquired verified authority")
		}
		count, err := db.Collection("sources").CountDocuments(ctx, bson.M{})
		if err != nil || count != 1 {
			t.Fatalf("source identity changed across extractor versions: count=%d err=%v", count, err)
		}
		var source store.Source
		if err := db.Collection("sources").FindOne(ctx, bson.M{}).Decode(&source); err != nil {
			t.Fatal(err)
		}
		if source.Content != fixed["raw_transcript"].(string) {
			t.Fatal("immutable source text changed across extractor versions")
		}
		t.Logf("%s legacy=%s corrected=%s source=%s status=%s retry=%s",
			backend.name, old.StableID, current.StableID, source.SourceHash, node.Status, again.Status)
		identities[backend.name] = []string{old.StableID, current.StableID}
	}
	if identities["native"][0] == identities["go"][0] ||
		identities["native"][1] != identities["go"][1] {
		t.Fatal("legacy divergence was not reproduced or corrected candidate identities differ")
	}
}

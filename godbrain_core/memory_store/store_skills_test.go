package memorystore

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

type skillParityFixture struct {
	Ranking []struct {
		Query, Name, Content string
		Score                int
	}
	Eligibility []struct {
		Mutation string
		Eligible bool
	}
}

func readSkillParity(t *testing.T) skillParityFixture {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "skill_lookup_parity.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture skillParityFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func TestSkillRankingParity(t *testing.T) {
	for _, test := range readSkillParity(t).Ranking {
		if score := skillRelevance(test.Query, test.Name, test.Content); score != test.Score {
			t.Errorf("%s: score %d, want %d", test.Name, score, test.Score)
		}
	}
	if terms := skillQueryTerms("one two three four five six seven eight nine ten"); len(terms) != 8 {
		t.Fatalf("query terms are not bounded: %v", terms)
	}
}

func TestCurrentSkillLookupParity(t *testing.T) {
	uri := os.Getenv("MONGODB_TEST_URI")
	if uri == "" {
		t.Skip("MONGODB_TEST_URI is required for current-skill Mongo joins")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	db := client.Database("godbrain_go_skill_test_" + primitive.NewObjectID().Hex())
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := db.Drop(cleanup); err != nil {
			t.Error(err)
		}
		if err := client.Disconnect(cleanup); err != nil {
			t.Error(err)
		}
	})
	insert := func(collection string, document any) {
		t.Helper()
		if _, err := db.Collection(collection).InsertOne(ctx, document); err != nil {
			t.Fatal(err)
		}
	}
	seed := func(mutation, name string, created int64) {
		t.Helper()
		id := primitive.NewObjectID()
		content := "Steps to rollback the display safely."
		profile := "desk-v1"
		switch {
		case strings.HasPrefix(mutation, "broad-"):
			profile = "galaxy-html-v1"
		case mutation == "apply-only":
			profile = "local-edit-apply-v1"
		case mutation == "unknown-profile":
			profile = "unknown"
		}
		node := KnowledgeNode{ID: id, Version: "v1", Status: "verified", Sector: "test", Content: content}
		switch mutation {
		case "stale-origin":
			node.Status = "stale"
		case "candidate-origin":
			node.Status = "candidate"
		case "personal-origin":
			node.Sector = "personal"
		}
		if mutation != "missing-origin" {
			insert("knowledge_nodes", node)
		}
		if mutation != "missing-link" {
			insert("run_node_links", RunNodeLink{NodeID: id, RunID: id.Hex()})
		}
		state := StatusCommitted
		if mutation == "uncommitted" {
			state = StatusStaging
		}
		insert("ingestion_runs", bson.M{"run_id": id.Hex(), "status": state})
		hash := sha3.NewLegacyKeccak256()
		hash.Write([]byte(content))
		skill := Skill{Name: name, Content: content, OriginNodeID: id.Hex(), OriginVersion: "v1",
			OriginHash: hex.EncodeToString(hash.Sum(nil)), VerificationProfile: profile,
			VerificationRunID: "run-a", CreatedAt: time.UnixMilli(created)}
		switch mutation {
		case "version-mismatch":
			skill.OriginVersion = "v2"
		case "hash-mismatch":
			skill.OriginHash = strings.Repeat("0", 64)
		case "rewritten-content":
			skill.Content = "Unrelated rewrite."
		case "missing-promotion-evidence":
			skill.VerificationRunID = ""
		}
		insert("skills", skill)
		evidence := func(fixture, result, profile string, at int64) {
			runID := "run-a"
			if at == 2 {
				runID = "run-b"
			}
			if at == 3 {
				runID = "run-c"
			}
			insert("skill_verification_runs", SkillVerificationRun{RunID: runID,
				SkillName: name, OriginNodeID: id.Hex(), FixtureID: fixture, Result: result,
				VerificationProfile: profile, CreatedAt: time.UnixMilli(at)})
		}
		if mutation != "missing-run" {
			evidence("a", SkillRunPassed, profile, 1)
		}
		switch mutation {
		case "later-fail", "later-pass":
			evidence("a", SkillRunFailed, profile, 2)
			if mutation == "later-pass" {
				evidence("a", SkillRunPassed, profile, 3)
			}
		case "broad-two":
			evidence("b", SkillRunPassed, profile, 2)
		case "broad-stale-fixture":
			evidence("b", SkillRunFailed, profile, 2)
			evidence("a", SkillRunPassed, profile, 3)
		case "profile-mismatch":
			evidence("a", SkillRunPassed, "galaxy-html-v1", 2)
			evidence("b", SkillRunPassed, "galaxy-html-v1", 3)
		}
	}
	store := NewStore(db)
	for _, test := range readSkillParity(t).Eligibility {
		if err := db.Drop(ctx); err != nil {
			t.Fatal(err)
		}
		seed(test.Mutation, "display-rollback", 1)
		skills, err := store.QueryPromotedSkills(ctx, "rollback display", 25)
		if err != nil {
			t.Fatal(err)
		}
		if (len(skills) == 1) != test.Eligible || len(skills) > 1 {
			t.Fatalf("%s: eligible=%v, returned %d skills", test.Mutation, test.Eligible, len(skills))
		}
	}
	if err := db.Drop(ctx); err != nil {
		t.Fatal(err)
	}
	seed("fresh", "display-rollback", 1)
	seed("fresh", "display-guide", 2)
	skills, err := store.QueryPromotedSkills(ctx, "rollback display", 1)
	if err != nil || len(skills) != 1 || skills[0].Name != "display-rollback" {
		t.Fatalf("relevance lost to recency: %+v, %v", skills, err)
	}
	skills, err = store.QueryPromotedSkills(ctx, ".*", 25)
	if err != nil || len(skills) != 0 {
		t.Fatalf("regex query was not literal: %+v, %v", skills, err)
	}
}

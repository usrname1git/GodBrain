package memorystore

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"golang.org/x/crypto/sha3"
)

func TestKnowledgeNodeFilter(t *testing.T) {
	oid := primitive.NewObjectID()
	byID := knowledgeNodeFilter(oid.Hex())
	got, ok := byID["_id"].(primitive.ObjectID)
	if !ok || got != oid {
		t.Fatalf("object id filter = %#v", byID)
	}
	stable := strings.Repeat("ab", 32)
	byStable := knowledgeNodeFilter("  " + stable + " ")
	if byStable["stable_id"] != stable {
		t.Fatalf("stable filter = %#v", byStable)
	}
	if _, exists := byStable["_id"]; exists {
		t.Fatal("stable id must not query _id")
	}
}

func TestBSONKeepsInteriorNUL(t *testing.T) {
	raw, err := bson.Marshal(bson.M{"content": "a\x00b"})
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		Content string `bson:"content"`
	}
	if err := bson.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Content != "a\x00b" {
		t.Fatalf("stored content = %q", back.Content)
	}
}

func TestIdentityParityFixture(t *testing.T) {
	f, err := os.Open("../testdata/identity_parity.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p := strings.Split(line, "\t")
		switch p[0] {
		case "decode":
			if len(p) != 5 {
				t.Fatalf("decode fields: %q", line)
			}
			var text string
			if err := json.Unmarshal([]byte(p[2]), &text); err != nil {
				t.Fatalf("%s: %v", p[1], err)
			}
			if hex.EncodeToString([]byte(text)) != p[3] {
				t.Fatalf("%s bytes = %s", p[1], hex.EncodeToString([]byte(text)))
			}
			hash := sha3.NewLegacyKeccak256()
			_, _ = hash.Write([]byte(text))
			if hex.EncodeToString(hash.Sum(nil)) != p[4] {
				t.Fatalf("%s hash = %s", p[1], hex.EncodeToString(hash.Sum(nil)))
			}
		case "span":
			if len(p) != 5 {
				t.Fatalf("span fields: %q", line)
			}
			source, err := hex.DecodeString(p[2])
			if err != nil {
				t.Fatalf("%s hex: %v", p[1], err)
			}
			err = validateEvidenceSpans([]string{p[3]}, string(source))
			wantOK := p[4] == "ok"
			if (err == nil) != wantOK {
				t.Fatalf("%s ok=%v err=%v", p[1], err == nil, err)
			}
		default:
			t.Fatalf("unknown kind %s", p[0])
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
}

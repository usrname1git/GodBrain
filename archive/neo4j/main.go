package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

// MemoryPayload represents the distilled golden record from the Librarian (Python)
type MemoryPayload struct {
	SessionID string   `json:"session_id"`
	Concepts  []string `json:"core_concepts"`
	OpSec     []string `json:"opsec_rules"`
	Summary   string   `json:"summary"`
}

func main() {
	// Aura Cloud credentials from environment
	uri := os.Getenv("NEO4J_URI")
	user := os.Getenv("NEO4J_USERNAME")
	pass := os.Getenv("NEO4J_PASSWORD")

	if uri == "" || user == "" || pass == "" {
		log.Fatal("[FATAL] Missing NEO4J_URI, NEO4J_USERNAME, or NEO4J_PASSWORD environment variables")
	}

	// 1. Setup robust driver (Go handles connection pooling & routing 100x better than Python)
	ctx := context.Background()
	driver, err := neo4j.NewDriverWithContext(uri, neo4j.BasicAuth(user, pass, ""))
	if err != nil {
		log.Fatalf("[FATAL] Failed to create Neo4j driver: %v", err)
	}
	defer driver.Close(ctx)

	// 2. Verify connectivity (This will fail fast if Aura is paused, giving us a clean exit)
	err = driver.VerifyConnectivity(ctx)
	if err != nil {
		log.Fatalf("[FATAL] Failed to verify connectivity (Aura might be paused): %v", err)
	}

	// 3. Read distilled JSON payload from Python via Stdin
	inputBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		log.Fatalf("[FATAL] Failed to read stdin: %v", err)
	}

	var payload MemoryPayload
	if err := json.Unmarshal(inputBytes, &payload); err != nil {
		log.Fatalf("[FATAL] Failed to parse JSON: %v", err)
	}

	// 4. Inject Golden Record into the GodBrain Graph
	session := driver.NewSession(ctx, neo4j.SessionConfig{AccessMode: neo4j.AccessModeWrite})
	defer session.Close(ctx)

	_, err = session.ExecuteWrite(ctx, func(tx neo4j.ManagedTransaction) (any, error) {
		query := `
			MERGE (s:Session {id: $session_id})
			SET s.summary = $summary, s.timestamp = datetime()
			WITH s

			// Link core concepts. FOREACH (not UNWIND) so an empty $concepts
			// list is a no-op instead of dropping the row and silently
			// discarding the Session write that already happened above.
			FOREACH (concept IN $concepts |
				MERGE (c:Concept {name: concept})
				MERGE (s)-[:LEARNED]->(c)
			)

			WITH s
			// Link OpSec rules, same empty-list-safe pattern.
			FOREACH (rule IN $opsec |
				MERGE (o:OpSecRule {rule: rule})
				MERGE (s)-[:ESTABLISHED]->(o)
			)
		`
		params := map[string]any{
			"session_id": payload.SessionID,
			"summary":    payload.Summary,
			"concepts":   payload.Concepts,
			"opsec":      payload.OpSec,
		}
		result, err := tx.Run(ctx, query, params)
		if err != nil {
			return nil, err
		}
		// tx.Run only queues the query; the driver doesn't actually execute it
		// (and surface any Cypher/runtime error) until the result is consumed.
		// Without this, a bad query would silently report success.
		summary, err := result.Consume(ctx)
		if err != nil {
			return nil, err
		}
		return summary, nil
	})

	if err != nil {
		log.Fatalf("[FATAL] Failed to write to graph: %v", err)
	}

	fmt.Println("[SUCCESS] Memory committed to Aura via robust Go engine.")
}

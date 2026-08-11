package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var db *mongo.Database

// isTrustedOrigin mirrors the C++ kernel router's origin allow-list: only
// localhost/127.0.0.1 on any port (dev servers, the packaged UI, etc.) and
// the Tauri webview origins may talk to this loopback-only API. No wildcard
// is ever accepted.
func isTrustedOrigin(origin string) bool {
	if origin == "" {
		return false
	}
	if origin == "tauri://localhost" {
		return true
	}
	schemeEnd := strings.Index(origin, "://")
	if schemeEnd == -1 {
		return false
	}
	rest := origin[schemeEnd+3:]
	if slash := strings.Index(rest, "/"); slash != -1 {
		rest = rest[:slash]
	}
	host := rest
	if colon := strings.Index(rest, ":"); colon != -1 {
		host = rest[:colon]
	}
	return host == "localhost" || host == "127.0.0.1" || host == "tauri.localhost"
}

func initDB() {
	// mongo.Connect never actually dials the server: without a bounded Ping
	// right after, a dead/unreachable Mongo instance would only surface as a
	// mysterious failure on the first real query instead of a clean startup
	// error.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	clientOptions := options.Client().ApplyURI("mongodb://localhost:27017/")
	client, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		log.Fatalf("[FATAL] failed to construct MongoDB client: %v", err)
	}
	if err := client.Ping(ctx, nil); err != nil {
		log.Fatalf("[FATAL] failed to reach MongoDB at %s within 10s: %v", "mongodb://localhost:27017/", err)
	}
	db = client.Database("godbrain")
	log.Println("Connected to MongoDB!")
}

// exeDir returns the directory containing the running binary, or "" if it
// cannot be determined (e.g. under `go run`, where os.Executable() points at
// a throwaway build-cache binary rather than anything repo-relative).
func exeDir() string {
	exePath, err := os.Executable()
	if err != nil {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(exePath)
	if err != nil {
		resolved = exePath
	}
	return filepath.Dir(resolved)
}

// firstExistingPath returns the first candidate that exists on disk, or the
// first non-empty candidate (logging a warning) if none do, so callers still
// get a deterministic best-effort path instead of an empty string.
func firstExistingPath(what string, candidates ...string) string {
	var fallback string
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if fallback == "" {
			fallback = c
		}
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	if fallback != "" {
		log.Printf("[WARN] could not locate %s via any repo-relative candidate; using best-effort path %q", what, fallback)
	}
	return fallback
}

// resolveColibriPath finds the Colibri C-Engine executable: an explicit
// GODBRAIN_COLIBRI_PATH always wins, otherwise it is resolved relative to the
// current working directory (the common case: this binary is run from the
// repository root) and to the running executable's own directory (the case
// where it has been built/copied elsewhere), so no single user's absolute
// path is ever baked in.
func resolveColibriPath() string {
	if v := os.Getenv("GODBRAIN_COLIBRI_PATH"); v != "" {
		return v
	}
	dir := exeDir()
	return firstExistingPath("colibri.exe",
		filepath.Join("LLM", "colibri_LLM", "c", "colibri.exe"),
		filepath.Join(dir, "LLM", "colibri_LLM", "c", "colibri.exe"),
		filepath.Join(dir, "..", "LLM", "colibri_LLM", "c", "colibri.exe"),
	)
}

// resolveFrontendDir finds the static Galaxy UI directory using the same
// env-override-then-repo-relative strategy.
func resolveFrontendDir() string {
	if v := os.Getenv("GODBRAIN_FRONTEND_DIR"); v != "" {
		return v
	}
	dir := exeDir()
	return firstExistingPath("frontend directory",
		filepath.Join("godbrain_core", "frontend"),
		filepath.Join(dir, "godbrain_core", "frontend"),
		filepath.Join(dir, "..", "frontend"),
		"../frontend",
	)
}

// resolveSnapshotPath finds the Colibri model snapshot directory. Unlike the
// paths above this is inherently a machine-specific data location (e.g. a
// dedicated NVMe drive), so there is no repo-relative default worth probing —
// just an explicit override with a documented fallback.
func resolveSnapshotPath() string {
	if v := os.Getenv("GODBRAIN_SNAPSHOT_PATH"); v != "" {
		return v
	}
	return `C:\nvme\glm52`
}

type ChatRequest struct {
	Message string `json:"message"`
}

func main() {
	initDB()

	frontendDir := resolveFrontendDir()

	r := gin.Default()
	corsConfig := cors.Config{
		AllowOriginFunc:  isTrustedOrigin,
		AllowMethods:     []string{"GET", "POST", "OPTIONS"},
		AllowHeaders:     []string{"Origin", "Content-Type", "Authorization"},
		AllowCredentials: false,
		MaxAge:           12 * time.Hour,
	}
	r.Use(cors.New(corsConfig))

	// Serve the static frontend
	r.Static("/frontend", frontendDir)

	r.GET("/", func(c *gin.Context) {
		c.Redirect(http.StatusFound, "/galaxy")
	})

	r.GET("/galaxy", func(c *gin.Context) {
		c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
		c.File(filepath.Join(frontendDir, "galaxy.html"))
	})

	r.GET("/api/test", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "reloaded! GO POWER"})
	})

	r.GET("/api/graph", func(c *gin.Context) {
		collection := db.Collection("nodes")
		opts := options.Find().SetProjection(bson.D{
			{Key: "title", Value: 1},
			{Key: "type", Value: 1},
			{Key: "tags", Value: 1},
		})
		cursor, err := collection.Find(context.TODO(), bson.D{}, opts)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		defer cursor.Close(context.TODO())

		var nodes []bson.M
		if err = cursor.All(context.TODO(), &nodes); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		var results []map[string]interface{}
		validNodeIds := make(map[string]bool)

		for _, n := range nodes {
			id := n["_id"].(primitive.ObjectID).Hex()
			validNodeIds[id] = true

			title, _ := n["title"].(string)
			nodeType, _ := n["type"].(string)

			group := "General"
			titleLower := strings.ToLower(title)
			typeLower := strings.ToLower(nodeType)

			if strings.Contains(titleLower, "rust") || strings.Contains(typeLower, "rust") {
				group = "Rust"
			} else if strings.Contains(titleLower, "windows") || strings.Contains(titleLower, "sre") {
				group = "Windows SRE / Optimization"
			}

			results = append(results, map[string]interface{}{
				"id":    id,
				"label": title,
				"group": group,
				"type":  nodeType,
				"val":   1.5,
			})
		}

		c.JSON(http.StatusOK, gin.H{"nodes": results, "links": []interface{}{}})
	})

	r.GET("/api/node", func(c *gin.Context) {
		nodeID := c.Query("id")
		if nodeID == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "No ID provided"})
			return
		}

		collection := db.Collection("nodes")
		var node bson.M

		objID, err := primitive.ObjectIDFromHex(nodeID)
		if err == nil {
			err = collection.FindOne(context.TODO(), bson.M{"_id": objID}).Decode(&node)
		} else {
			err = collection.FindOne(context.TODO(), bson.M{"title": nodeID}).Decode(&node)
		}

		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "Node not found"})
			return
		}

		node["_id"] = node["_id"].(primitive.ObjectID).Hex()
		c.JSON(http.StatusOK, node)
	})

	r.POST("/api/chat", func(c *gin.Context) {
		var req ChatRequest
		if err := c.ShouldBindJSON(&req); err != nil || req.Message == "" {
			c.JSON(http.StatusBadRequest, gin.H{"response": "I cannot hear you. Message was empty."})
			return
		}

		log.Printf("[RAG] User asked: %s", req.Message)

		// Build Context
		regexPattern := ""
		words := regexp.MustCompile(`\b\w+\b`).FindAllString(strings.ToLower(req.Message), -1)
		var keywords []string
		stopWords := map[string]bool{"what": true, "when": true, "where": true, "will": true, "this": true, "that": true, "delete": true, "disable": true, "change": true, "remove": true, "need": true, "right": true}

		for _, w := range words {
			if len(w) > 3 && !stopWords[w] {
				keywords = append(keywords, w)
			}
		}

		contextText := "Knowledge Graph Context:\n"
		if len(keywords) > 0 {
			regexPattern = strings.Join(keywords, "|")
			log.Printf("[RAG] Searching graph for: %s", regexPattern)

			collection := db.Collection("nodes")
			filter := bson.D{
				{Key: "$or", Value: bson.A{
					bson.D{{Key: "title", Value: bson.D{{Key: "$regex", Value: primitive.Regex{Pattern: regexPattern, Options: "i"}}}}},
					bson.D{{Key: "content", Value: bson.D{{Key: "$regex", Value: primitive.Regex{Pattern: regexPattern, Options: "i"}}}}},
				}},
			}

			opts := options.Find().SetLimit(3)
			cursor, err := collection.Find(context.TODO(), filter, opts)
			var relevantNodes []bson.M
			if err != nil {
				log.Printf("[RAG] graph search failed: %v", err)
			} else {
				func() {
					defer cursor.Close(context.TODO())
					if err := cursor.All(context.TODO(), &relevantNodes); err != nil {
						log.Printf("[RAG] failed to decode graph search results: %v", err)
						relevantNodes = nil
					}
				}()
			}

			if len(relevantNodes) > 0 {
				for i, n := range relevantNodes {
					title, _ := n["title"].(string)
					content, _ := n["content"].(string)
					if len(content) > 500 {
						content = content[:500]
					}
					contextText += fmt.Sprintf("\n--- Source %d: %s ---\n%s...\n", i+1, title, content)
				}
			} else {
				contextText += "No exact matches found in local graph.\n"
			}
		} else {
			contextText += "No specific keywords extracted.\n"
		}

		log.Println("[RAG] Context built. Executing Colibri via Go...")

		systemPrompt := "You are GodBrain, the Sovereign SRE Agent. You help the user optimize Windows 11 safely. Use the Knowledge Graph Context provided below to answer the user's question. If a tweak FATALLY_BREAKS something, WARN THE USER aggressively."
		fullPrompt := fmt.Sprintf("%s\n\n%s\n\nUser Question: %s\nAnswer:", systemPrompt, contextText, req.Message)

		// Setup Command
		coliPath := resolveColibriPath()

		// In Go, exec.Command manages the pipes internally, and Wait() handles them cleanly without deadlocks.
		// We pass NUL via Stdin explicitly to close it immediately.
		cmd := exec.Command(coliPath, "64", "8", "8")

		cmd.Env = append(os.Environ(),
			`SNAP=`+resolveSnapshotPath(),
			`COLI_PROMPT=`+fullPrompt,
			`NGEN=64`,
			`COLI_RAM_OVERCOMMIT=1`,
			`COLI_CUDA=1`,
			`CUDA_EXPERT_GB=12`,
		)

		// Pass a closed buffer as stdin (equivalent to < NUL)
		cmd.Stdin = bytes.NewReader([]byte{})

		var outbuf, errbuf bytes.Buffer
		cmd.Stdout = &outbuf
		cmd.Stderr = &errbuf

		// Start process
		err := cmd.Start()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"response": fmt.Sprintf("Failed to start colibri: %v", err)})
			return
		}

		// Channel for timeout
		done := make(chan error, 1)
		go func() {
			done <- cmd.Wait()
		}()

		select {
		case <-time.After(180 * time.Second):
			// Kill only the process we spawned. A process-name-wide taskkill
			// would terminate every colibri.exe on the machine, including any
			// unrelated instances a user is running directly.
			if err := cmd.Process.Kill(); err != nil {
				log.Printf("[RAG] failed to kill timed-out colibri process (pid %d): %v", cmd.Process.Pid, err)
			}
			c.JSON(http.StatusGatewayTimeout, gin.H{"response": "System fault. Colibri C-Engine timed out."})
			return
		case err := <-done:
			if err != nil {
				log.Printf("Colibri exited with error: %v", err)
			}
		}

		output := outbuf.String() + errbuf.String()

		// Parse Output
		var finalAnswer string
		if strings.Contains(output, "ATTENTION:") {
			parts := strings.Split(output, "ATTENTION:")
			lastPart := parts[len(parts)-1]
			// The marker isn't guaranteed to be followed by a newline (e.g. it
			// could be the very end of the output); SplitN then returns a
			// single-element slice and indexing [1] would panic.
			if segments := strings.SplitN(lastPart, "\n", 2); len(segments) > 1 {
				finalAnswer = segments[1]
			} else {
				finalAnswer = lastPart
			}
		} else if strings.Contains(output, "Answer:") {
			parts := strings.Split(output, "Answer:")
			finalAnswer = parts[len(parts)-1]
		} else {
			lines := strings.Split(output, "\n")
			if len(lines) > 10 {
				finalAnswer = strings.Join(lines[len(lines)-10:], "\n")
			} else {
				finalAnswer = output
			}
		}

		finalAnswer = strings.TrimSpace(finalAnswer)
		if len(finalAnswer) > 50 {
			log.Printf("[RAG] Answer generated: %s...", finalAnswer[:50])
		} else {
			log.Printf("[RAG] Answer generated: %s", finalAnswer)
		}

		c.JSON(http.StatusOK, gin.H{"response": finalAnswer})
	})

	r.Run("127.0.0.1:8082") // Loopback only; running on 8082 to test alongside python
}

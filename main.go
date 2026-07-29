package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
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

func initDB() {
	clientOptions := options.Client().ApplyURI("mongodb://localhost:27017/")
	client, err := mongo.Connect(context.TODO(), clientOptions)
	if err != nil {
		log.Fatal(err)
	}
	db = client.Database("godbrain")
	log.Println("Connected to MongoDB!")
}

type ChatRequest struct {
	Message string `json:"message"`
}

func main() {
	initDB()

	r := gin.Default()
	r.Use(cors.Default())

	// Serve the static frontend
	r.Static("/frontend", "../frontend")

	r.GET("/", func(c *gin.Context) {
		c.Redirect(http.StatusFound, "/galaxy")
	})

	r.GET("/galaxy", func(c *gin.Context) {
		c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
		c.File("../frontend/galaxy.html")
	})

	r.GET("/api/test", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "reloaded! GO POWER"})
	})

	r.GET("/api/graph", func(c *gin.Context) {
		collection := db.Collection("nodes")
		opts := options.Find().SetProjection(bson.D{{"title", 1}, {"type", 1}, {"tags", 1}})
		cursor, err := collection.Find(context.TODO(), bson.D{}, opts)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		
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
				"id": id,
				"label": title,
				"group": group,
				"type": nodeType,
				"val": 1.5,
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
				{"$or", bson.A{
					bson.D{{"title", bson.D{{"$regex", primitive.Regex{Pattern: regexPattern, Options: "i"}}}}},
					bson.D{{"content", bson.D{{"$regex", primitive.Regex{Pattern: regexPattern, Options: "i"}}}}},
				}},
			}
			
			opts := options.Find().SetLimit(3)
			cursor, _ := collection.Find(context.TODO(), filter, opts)
			var relevantNodes []bson.M
			cursor.All(context.TODO(), &relevantNodes)
			
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
		coliPath := `C:\Users\autismo\Documents\GitHub\GodBrain\LLM\colibri_LLM\c\colibri.exe`
		
		// In Go, exec.Command manages the pipes internally, and Wait() handles them cleanly without deadlocks.
		// We pass NUL via Stdin explicitly to close it immediately.
		cmd := exec.Command(coliPath, "64", "8", "8")
		
		cmd.Env = append(os.Environ(),
			`SNAP=C:\nvme\glm52`,
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
			cmd.Process.Kill()
			exec.Command("taskkill", "/F", "/IM", "colibri.exe").Run()
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
			finalAnswer = strings.SplitN(parts[len(parts)-1], "\n", 2)[1]
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

	r.Run(":8082") // Running on 8082 to test alongside python
}

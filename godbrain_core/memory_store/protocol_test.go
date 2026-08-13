package memorystore

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"golang.org/x/crypto/sha3"
)

func TestValidateDocumentPayload(t *testing.T) {
	raw := "hello \u00e5"
	contentHash := sha256.Sum256([]byte(raw))
	confidence := 0.75
	payload := DistillationPayload{
		RawTranscript: raw,
		Document: &DocumentMetadata{
			SourceLabel:      "local",
			DisplayName:      "scan.png",
			FileSHA256:       strings.Repeat("a", 64),
			ContentSHA256:    hex.EncodeToString(contentHash[:]),
			ExtractionMethod: "easyocr",
			Languages:        []string{"en", "sv"},
			Backend:          "easyocr",
			BackendVersion:   "1.7.2",
			ChunkCount:       1,
			OCRConfidence:    &confidence,
		},
		Chunks: []SourceChunk{{
			Index: 0, Count: 1, StartByte: 0, EndByte: len([]byte(raw)),
			Text: raw, Confidence: &confidence,
		}},
	}
	payload.ExtractorID = "Local-Document-Adapter"
	payload.ExtractorVersion = "1.0.0+easyocr-1.7.2"
	payload.SchemaVersion = "1.1-document"
	payload.Payload.Provenance.SourceID = "local-document:local:scan.png"
	payload.Payload.Provenance.SourceType = "local_document"
	payload.Payload.Provenance.Language = "en,sv"
	if err := ValidateDocumentPayload(payload); err != nil {
		t.Fatalf("expected valid document payload, got %v", err)
	}

	payload.Chunks[0].Text = "different"
	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected mismatched chunk text to fail")
	}
}

func TestValidatePreIngestionPayloadRejectsHashAndTrustBeforePersistence(t *testing.T) {
	payload := DistillationPayload{
		ExtractorVersion: "v1",
		SchemaVersion:    "1.0",
		RawTranscript:    "hello",
		Payload: AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: Provenance{
				SourceID: "session", SourceType: "session_transcript",
				SourceHash: "wrong", Language: "mixed",
			},
		},
	}
	if err := ValidatePreIngestionPayload(payload); err == nil {
		t.Fatal("expected mismatched legacy Keccak hash to fail")
	}

	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write([]byte(payload.RawTranscript))
	payload.Payload.Provenance.SourceHash = hex.EncodeToString(hash.Sum(nil))
	payload.Payload.TrustTier = "verified"
	if err := ValidatePreIngestionPayload(payload); err == nil {
		t.Fatal("expected non-candidate trust tier to fail")
	}
}

func TestValidateDocumentPayloadRejectsUnsafePathAndOverlappingChunks(t *testing.T) {
	raw := "hello world"
	contentHash := sha256.Sum256([]byte(raw))
	payload := DistillationPayload{
		ExtractorID: "Local-Document-Adapter", ExtractorVersion: "1.0.0", SchemaVersion: "1.1-document",
		RawTranscript: raw,
		Payload: AlexandriaPayload{Provenance: Provenance{
			SourceID:   "local-document:C:\\Users\\alice:a.txt",
			SourceType: "local_document", Language: "und",
		}},
		Document: &DocumentMetadata{
			SourceLabel: "C:\\Users\\alice", DisplayName: "a.txt",
			FileSHA256: strings.Repeat("a", 64), ContentSHA256: hex.EncodeToString(contentHash[:]),
			ExtractionMethod: "utf-8", Languages: []string{"und"},
			Backend: "python-codecs", BackendVersion: "3", ChunkCount: 1,
		},
		Chunks: []SourceChunk{{Index: 0, Count: 1, StartByte: 0, EndByte: len(raw), Text: raw}},
	}
	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected absolute source label to fail")
	}

	payload.Document.SourceLabel = "local"
	payload.Document.ChunkCount = 2
	payload.Payload.Provenance.SourceID = "local-document:local:a.txt"
	payload.Chunks = []SourceChunk{
		{Index: 0, Count: 2, StartByte: 0, EndByte: 5, Text: "hello"},
		{Index: 1, Count: 2, StartByte: 0, EndByte: 5, Text: "hello"},
	}
	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected overlapping source chunks to fail")
	}
}

func TestValidateDocumentPayloadRequiresMatchingContentSHA256(t *testing.T) {
	payload := DistillationPayload{
		ExtractorID: "Local-Document-Adapter", ExtractorVersion: "1.0.0", SchemaVersion: "1.1-document",
		RawTranscript: "hello",
		Payload: AlexandriaPayload{Provenance: Provenance{
			SourceID: "local-document:local:a.txt", SourceType: "local_document", Language: "und",
		}},
		Document: &DocumentMetadata{
			SourceLabel: "local", DisplayName: "a.txt",
			FileSHA256: strings.Repeat("a", 64), ContentSHA256: strings.Repeat("b", 64),
			ExtractionMethod: "utf-8", Languages: []string{"und"},
			Backend: "python-codecs", BackendVersion: "3", ChunkCount: 1,
		},
		Chunks: []SourceChunk{{Index: 0, Count: 1, StartByte: 0, EndByte: 5, Text: "hello"}},
	}
	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected mismatched content SHA-256 to fail")
	}
}

func TestValidateDocumentPayloadRejectsSensitiveContentBeforePersistence(t *testing.T) {
	raw := "otpauth://totp/Example?secret=SYNTHETIC"
	contentHash := sha256.Sum256([]byte(raw))
	payload := DistillationPayload{
		ExtractorID: "Local-Document-Adapter", ExtractorVersion: "1.0.0", SchemaVersion: "1.1-document",
		RawTranscript: raw,
		Payload: AlexandriaPayload{Provenance: Provenance{
			SourceID: "local-document:local:a.txt", SourceType: "local_document", Language: "und",
		}},
		Document: &DocumentMetadata{
			SourceLabel: "local", DisplayName: "a.txt",
			FileSHA256: strings.Repeat("a", 64), ContentSHA256: hex.EncodeToString(contentHash[:]),
			ExtractionMethod: "utf-8", Languages: []string{"und"},
			Backend: "python-codecs", BackendVersion: "3", ChunkCount: 1,
		},
		Chunks: []SourceChunk{{Index: 0, Count: 1, StartByte: 0, EndByte: len(raw), Text: raw}},
	}

	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected sensitive document content to fail")
	}
}

func TestValidateDocumentPayloadRejectsAdditionalTokenFormats(t *testing.T) {
	fixtures := []string{
		"AIza" + strings.Repeat("A", 35),
		"xoxb-" + strings.Repeat("A", 24),
		"sk_live_" + strings.Repeat("A", 20),
		"eyJ" + strings.Repeat("A", 10) + "." + strings.Repeat("B", 10) + "." + strings.Repeat("C", 10),
	}

	for _, raw := range fixtures {
		contentHash := sha256.Sum256([]byte(raw))
		payload := DistillationPayload{
			ExtractorID: "Local-Document-Adapter", ExtractorVersion: "1.0.0", SchemaVersion: "1.1-document",
			RawTranscript: raw,
			Payload: AlexandriaPayload{Provenance: Provenance{
				SourceID: "local-document:local:a.txt", SourceType: "local_document", Language: "und",
			}},
			Document: &DocumentMetadata{
				SourceLabel: "local", DisplayName: "a.txt",
				FileSHA256: strings.Repeat("a", 64), ContentSHA256: hex.EncodeToString(contentHash[:]),
				ExtractionMethod: "utf-8", Languages: []string{"und"},
				Backend: "python-codecs", BackendVersion: "3", ChunkCount: 1,
			},
			Chunks: []SourceChunk{{Index: 0, Count: 1, StartByte: 0, EndByte: len(raw), Text: raw}},
		}
		if err := ValidateDocumentPayload(payload); err == nil {
			t.Fatal("expected high-confidence token format to fail")
		}
	}
}

func TestValidateDocumentPayloadRequiresMetadataForLocalDiscriminator(t *testing.T) {
	payload := DistillationPayload{
		ExtractorID:      "Local-Document-Adapter",
		ExtractorVersion: "1.0.0",
		SchemaVersion:    "1.1-document",
		Payload: AlexandriaPayload{Provenance: Provenance{
			SourceID: "local-document:local:a.txt", SourceType: "local_document", Language: "und",
		}},
	}
	if err := ValidateDocumentPayload(payload); err == nil {
		t.Fatal("expected local document without metadata and chunks to fail")
	}
}

func TestValidateDocumentPayloadRejectsUnicodeWhitespaceCredential(t *testing.T) {
	for _, raw := range []string{
		"\u00a0api_key=syntheticcredentialvalue",
		"\u0085api_key=syntheticcredentialvalue",
		"heading\u2028api_key=syntheticcredentialvalue",
		"heading\rapi_key=syntheticcredentialvalue",
	} {
		contentHash := sha256.Sum256([]byte(raw))
		payload := DistillationPayload{
			ExtractorID: "Local-Document-Adapter", ExtractorVersion: "1.0.0", SchemaVersion: "1.1-document",
			RawTranscript: raw,
			Payload: AlexandriaPayload{Provenance: Provenance{
				SourceID: "local-document:local:a.txt", SourceType: "local_document", Language: "und",
			}},
			Document: &DocumentMetadata{
				SourceLabel: "local", DisplayName: "a.txt",
				FileSHA256: strings.Repeat("a", 64), ContentSHA256: hex.EncodeToString(contentHash[:]),
				ExtractionMethod: "utf-8", Languages: []string{"und"},
				Backend: "python-codecs", BackendVersion: "3", ChunkCount: 1,
			},
			Chunks: []SourceChunk{{Index: 0, Count: 1, StartByte: 0, EndByte: len([]byte(raw)), Text: raw}},
		}
		if err := ValidateDocumentPayload(payload); err == nil {
			t.Fatal("expected Unicode-whitespace credential assignment to fail")
		}
	}
}

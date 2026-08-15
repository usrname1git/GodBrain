package memorystore

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"golang.org/x/crypto/sha3"
)

func TestValidateStatusJudgmentAndTransitions(t *testing.T) {
	valid := StatusJudgment{
		Command: JudgmentCommand, ID: "claim:auth", Status: StatusVerified,
		Reasoning: "clicking the button actually saves the file",
	}
	if err := ValidateStatusJudgment(valid); err != nil {
		t.Fatalf("valid judgment rejected: %v", err)
	}
	tooShort := valid
	tooShort.Reasoning = "ok"
	if err := ValidateStatusJudgment(tooShort); !errors.Is(err, ErrJudgmentReasoningRequired) {
		t.Fatalf("short reasoning = %v", err)
	}
	if AllowedStatusTransition("rejected", "verified") {
		t.Fatal("rejected must be terminal")
	}
	if !AllowedStatusTransition("candidate", "verified") ||
		!AllowedStatusTransition("verified", "rejected") {
		t.Fatal("expected candidate->verified and verified->rejected")
	}
}

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

func TestValidatePreIngestionPayloadExtractorID(t *testing.T) {
	for _, extractorID := range []string{"", "Librarian-CPP-Colibri"} {
		t.Run("valid-"+extractorID, func(t *testing.T) {
			payload := validPreIngestionPayload(extractorID)
			if err := ValidatePreIngestionPayload(payload); err != nil {
				t.Fatalf("expected extractor ID %q to be valid, got %v", extractorID, err)
			}
		})
	}

	localPayload := validDocumentPayload("räksmörgås-東京.txt")
	if err := ValidatePreIngestionPayload(localPayload); err != nil {
		t.Fatalf("expected Local-Document-Adapter to be valid, got %v", err)
	}

	for _, extractorID := range []string{
		"contains space",
		"line\nbreak",
		"tab\tbreak",
		"control\u0085character",
		"-leading-hyphen",
	} {
		t.Run("invalid-"+extractorID, func(t *testing.T) {
			payload := validPreIngestionPayload(extractorID)
			if err := ValidatePreIngestionPayload(payload); err == nil {
				t.Fatalf("expected extractor ID %q to fail", extractorID)
			}
		})
	}
}

func TestValidateDocumentPayloadDisplayNameSafety(t *testing.T) {
	valid := validDocumentPayload("räksmörgås-東京.txt")
	if err := ValidateDocumentPayload(valid); err != nil {
		t.Fatalf("expected international printable display name to be valid, got %v", err)
	}

	for _, displayName := range []string{
		"colon:name.txt",
		"c1-\u0080.txt",
		"c1-\u0085.txt",
		"c1-\u009f.txt",
		"line\u2028separator.txt",
		"paragraph\u2029separator.txt",
	} {
		t.Run(displayName, func(t *testing.T) {
			payload := validDocumentPayload(displayName)
			if err := ValidateDocumentPayload(payload); err == nil {
				t.Fatalf("expected display name %q to fail", displayName)
			}
		})
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

func validPreIngestionPayload(extractorID string) DistillationPayload {
	raw := "hello"
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write([]byte(raw))
	return DistillationPayload{
		ExtractorID:      extractorID,
		ExtractorVersion: "v1",
		SchemaVersion:    "1.0",
		RawTranscript:    raw,
		Payload: AlexandriaPayload{
			TrustTier: "candidate",
			Provenance: Provenance{
				SourceID:   "session",
				SourceType: "session_transcript",
				SourceHash: hex.EncodeToString(hash.Sum(nil)),
				Language:   "mixed",
			},
		},
	}
}

func validDocumentPayload(displayName string) DistillationPayload {
	payload := validPreIngestionPayload("Local-Document-Adapter")
	contentHash := sha256.Sum256([]byte(payload.RawTranscript))
	payload.ExtractorVersion = "1.0.0"
	payload.SchemaVersion = "1.1-document"
	payload.Payload.Provenance.SourceID = "local-document:local:" + displayName
	payload.Payload.Provenance.SourceType = "local_document"
	payload.Payload.Provenance.Language = "und"
	payload.Document = &DocumentMetadata{
		SourceLabel:      "local",
		DisplayName:      displayName,
		FileSHA256:       strings.Repeat("a", 64),
		ContentSHA256:    hex.EncodeToString(contentHash[:]),
		ExtractionMethod: "utf-8",
		Languages:        []string{"und"},
		Backend:          "python-codecs",
		BackendVersion:   "3",
		ChunkCount:       1,
	}
	payload.Chunks = []SourceChunk{{
		Index: 0, Count: 1, StartByte: 0, EndByte: len(payload.RawTranscript),
		Text: payload.RawTranscript,
	}}
	return payload
}

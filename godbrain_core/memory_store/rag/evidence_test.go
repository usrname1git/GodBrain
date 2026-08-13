package rag

import "testing"

func TestResolveEvidenceValidatesUTF8ByteBoundaries(t *testing.T) {
	content := "a界bc"
	evidence, status, used := resolveEvidence(content, []string{
		"[1:4]",
		"[2:4]",
		"[4:6]",
		"invalid",
	}, 1024)
	if status != "partial" {
		t.Fatalf("expected partial status, got %q", status)
	}
	if len(evidence) != 2 {
		t.Fatalf("expected two byte-valid spans, got %#v", evidence)
	}
	if evidence[0].Excerpt != "界" || evidence[1].Excerpt != "bc" {
		t.Fatalf("unexpected excerpts %#v", evidence)
	}
	if used != len("界bc") {
		t.Fatalf("unexpected used byte count %d", used)
	}
	for _, citation := range evidence {
		if !citation.ByteValid {
			t.Fatal("valid citation was not labeled byte-valid")
		}
	}
}

func TestResolveEvidenceDoesNotSplitExcerptUTF8(t *testing.T) {
	content := "界界界"
	evidence, status, used := resolveEvidence(content, []string{"[0:9]"}, 5)
	if status != "byte_valid" || len(evidence) != 1 {
		t.Fatalf("unexpected evidence result status=%q evidence=%#v", status, evidence)
	}
	if evidence[0].Excerpt != "界" || used != len("界") {
		t.Fatalf("excerpt split UTF-8 or exceeded budget: %#v used=%d", evidence[0], used)
	}
}

func TestResolveEvidenceFlagsMalformedOnly(t *testing.T) {
	evidence, status, used := resolveEvidence("text", []string{"[4:4]", "[9:10]"}, 32)
	if len(evidence) != 0 || status != "invalid" || used != 0 {
		t.Fatalf("expected invalid evidence result, got %#v %q %d", evidence, status, used)
	}
}

func TestValidProvenanceShapeBoundsCitationIdentifiers(t *testing.T) {
	provenance := Provenance{
		RunID:            "run",
		SourceHash:       "hash",
		ExternalSourceID: "session",
		ExtractorID:      "extractor",
		ExtractorVersion: "v1",
		SchemaVersion:    "s1",
	}
	if !validProvenanceShape(provenance) {
		t.Fatal("expected normal provenance identifiers to be accepted")
	}
	provenance.ExternalSourceID = string(make([]byte, 513))
	if validProvenanceShape(provenance) {
		t.Fatal("oversized provenance must not enter a bounded response")
	}
}

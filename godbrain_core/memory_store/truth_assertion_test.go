package memorystore

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestTruthObservationProtocolParity(t *testing.T) {
	input, err := os.ReadFile("../testdata/truth_observation_parity.json")
	if err != nil {
		t.Fatal(err)
	}

	decode := func(raw []byte) (DistillationPayload, error) {
		var payload DistillationPayload
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&payload); err != nil {
			return payload, err
		}
		if _, err := decoder.Token(); err != io.EOF {
			return payload, fmt.Errorf("trailing input: %v", err)
		}
		return payload, ValidatePreIngestionPayload(payload)
	}
	payload, err := decode(input)
	if err != nil {
		t.Fatal(err)
	}
	if payload.ExtractorID != "Kernel-Truth-CPP" || payload.ExtractorVersion != "1.0.0" ||
		payload.SchemaVersion != "1.0" || len(payload.Payload.Claims) != 1 {
		t.Fatal("existing ingestion identities changed")
	}
	claim := payload.Payload.Claims[0]
	if err := validateEvidenceSpans(claim.EvidenceSpans, payload.RawTranscript); err != nil {
		t.Fatal(err)
	}
	if claim.EvidenceSpans[0] != fmt.Sprintf("[0:%d]", len(payload.RawTranscript)) ||
		payload.Payload.Provenance.SourceID != "truth:"+payload.Payload.Provenance.SourceHash ||
		payload.Payload.Provenance.SourceType != "kernel_truth_observation" ||
		!strings.Contains(claim.Content, "checker_version=1.0.0\n") {
		t.Fatal("assertion lost its complete source, evidence span or checker version")
	}
	if hasMismatchedOSPin(claim.Content, "Core/26100.0") ||
		!hasMismatchedOSPin(claim.Content, "Core/26100.1") {
		t.Fatal("assertion bypassed existing OS-pin applicability")
	}
	for _, test := range []struct {
		name string
		raw  []byte
	}{
		{"hash", bytes.Replace(input, []byte(`"raw_transcript": "`), []byte(`"raw_transcript": "changed `), 1)},
		{"trust", bytes.Replace(input, []byte(`"trust_tier": "candidate"`), []byte(`"trust_tier": "verified"`), 1)},
		{"unknown", bytes.Replace(input, []byte(`"degraded": false`), []byte(`"new_wire_field": true, "degraded": false`), 1)},
		{"trailing", append(append([]byte{}, input...), []byte("{}")...)},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decode(test.raw); err == nil {
				t.Fatal("invalid assertion envelope was accepted")
			}
		})
	}
}

func TestTruthObservationRoundTrip(t *testing.T) {
	input, err := os.ReadFile("../testdata/truth_observation_roundtrip_parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Envelope       json.RawMessage `json:"envelope"`
		KernelStableID string          `json:"kernel_stable_id"`
	}
	if err := json.Unmarshal(input, &fixture); err != nil {
		t.Fatal(err)
	}
	var payload DistillationPayload
	decoder := json.NewDecoder(bytes.NewReader(fixture.Envelope))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if err := ValidatePreIngestionPayload(payload); err != nil {
		t.Fatal(err)
	}
	var raw struct {
		Observation map[string]any `json:"observation"`
	}
	if err := json.Unmarshal([]byte(payload.RawTranscript), &raw); err != nil {
		t.Fatal(err)
	}
	claim := normalizeClaim(payload.Payload.Claims[0])
	start := strings.Index(claim.Content, "observation=")
	end := strings.LastIndex(claim.Content, "evidence_keccak256=")
	if start < 0 || end <= start {
		t.Fatal("observation framing is missing")
	}
	var observed map[string]any
	if err := json.Unmarshal(
		[]byte(claim.Content[start+len("observation="):end]), &observed,
	); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(observed, raw.Observation) {
		t.Fatal("claim normalization changed exact observation values, paths, names or details")
	}
	if fixture.KernelStableID == "" || claimStableID(claim) != fixture.KernelStableID {
		t.Fatal("Go persisted node identity differs from the C++ kernel judgment target")
	}
	if err := validateEvidenceSpans(claim.EvidenceSpans, payload.RawTranscript); err != nil {
		t.Fatal(err)
	}
}

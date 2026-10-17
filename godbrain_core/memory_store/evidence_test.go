package memorystore

import (
	"strings"
	"testing"
)

func TestEvidencePolicy(t *testing.T) {
	const checked int64 = 1000000
	for _, test := range []struct {
		profile               string
		checked, expires, now int64
		want                  bool
	}{
		{"host", checked, checked + HostTTLMS, checked, true},
		{"host", checked, checked + HostTTLMS, checked + HostTTLMS - 1, true},
		{"host", checked, checked + HostTTLMS, checked + HostTTLMS, false},
		{"host", checked, checked + DocumentTTLMS, checked, false},
		{"document", checked, checked + DocumentTTLMS, checked + DocumentTTLMS - 1, true},
		{"document", checked, checked + DocumentTTLMS, checked + DocumentTTLMS, false},
		{"document", checked, checked + DocumentTTLMS, checked - 1, false},
		{"document", 0, DocumentTTLMS, 1, false},
		{"unknown", checked, checked + DocumentTTLMS, checked, false},
	} {
		if EvidenceWindow(test.profile, test.checked, test.expires, test.now) != test.want {
			t.Fatalf("expiry/fake clock policy: %+v", test)
		}
	}
	for attempts, want := range map[int]int64{0: 60000, 1: 60000, 2: 120000, 3: 240000,
		4: 480000, 5: 960000, 6: DocumentTTLMS, 99: DocumentTTLMS} {
		if EvidenceBackoff(attempts) != want {
			t.Fatalf("backoff %d", attempts)
		}
	}
	request := EvidenceRequest{Command: "evidence", Action: "complete", ID: strings.Repeat("a", 64),
		LeaseToken: strings.Repeat("b", 24), Outcome: "fresh", Reason: "exact_source_unchanged",
		ObservedHash: strings.Repeat("c", 64)}
	if ValidateEvidenceRequest(request) != nil {
		t.Fatal("valid result rejected")
	}
	request.Successor = strings.Repeat("d", 64)
	if ValidateEvidenceRequest(request) == nil {
		t.Fatal("freshness accepted an unrelated successor")
	}
	request.Successor = ""
	request.ObservedHash = ""
	if ValidateEvidenceRequest(request) == nil {
		t.Fatal("freshness without source identity accepted")
	}
	request = EvidenceRequest{Command: "evidence", Action: "next"}
	if ValidateEvidenceRequest(request) != nil {
		t.Fatal("next rejected")
	}
	request.Outcome = "fresh"
	if ValidateEvidenceRequest(request) == nil {
		t.Fatal("next accepted a caller verdict")
	}
	for _, invalid := range []string{
		`{"command":"evidence","action":"next","id":null}`,
		`{"command":"evidence","action":"next","ttl":999999}`,
		`{"command":"evidence","action":"next"} {}`,
		`{"command":"evidence","action":"next","lease_token":123}`,
		`{"command":"evidence","action":"next","action":"status"}`,
		`{"command":"evidence","action":"next","Action":"status"}`,
		`{"command":"evidence","action":"next","a\u0063tion":"status"}`,
	} {
		if _, err := ParseEvidenceRequest([]byte(invalid)); err == nil {
			t.Fatalf("strict framing accepted %s", invalid)
		}
	}
	if EvidenceBinding(strings.Repeat("a", 24), "v1", "two  spaces") ==
		EvidenceBinding(strings.Repeat("a", 24), "v1", "two spaces") {
		t.Fatal("origin binding normalized significant bytes")
	}
}

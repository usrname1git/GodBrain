package memorystore

import "testing"

func TestParseEvidenceSpan(t *testing.T) {
	start, end, ok := parseEvidenceSpan("[0:4]")
	if !ok || start != 0 || end != 4 {
		t.Fatalf("valid span: %v %d %d", ok, start, end)
	}
	if _, _, ok := parseEvidenceSpan("0:4"); ok {
		t.Fatal("bare offsets must fail")
	}
	if _, _, ok := parseEvidenceSpan("[4:1]"); ok {
		t.Fatal("inverted span must fail")
	}
	if _, _, ok := parseEvidenceSpan("[2:2]"); ok {
		t.Fatal("empty span must fail")
	}
	if _, _, ok := parseEvidenceSpan("[0:4x]"); ok {
		t.Fatal("leftover characters must fail")
	}
	if _, _, ok := parseEvidenceSpan("[+0:4]"); ok {
		t.Fatal("signed offsets must fail")
	}
	if err := validateEvidenceSpans([]string{"[0:4]"}, "abcd"); err != nil {
		t.Fatalf("in-range span: %v", err)
	}
	if err := validateEvidenceSpans([]string{"[0:9]"}, "abcd"); err == nil {
		t.Fatal("past source end must fail")
	}
	if err := validateEvidenceSpans([]string{"[0:1]"}, ""); err == nil {
		t.Fatal("span on empty source must fail")
	}
	if err := validateEvidenceSpans([]string{"nope"}, "abcd"); err == nil {
		t.Fatal("malformed span must fail")
	}
	if err := validateEvidenceSpans([]string{"[0:1]"}, "世界"); err == nil {
		t.Fatal("split UTF-8 span must fail")
	}
}

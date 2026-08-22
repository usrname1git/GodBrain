package rag

import "testing"

func TestNormalizeSkillSearch(t *testing.T) {
	_, err := normalizeSkillSearch(SkillSearchRequest{})
	if err != ErrSkillQueryRequired {
		t.Fatalf("empty query = %v", err)
	}
	got, err := normalizeSkillSearch(SkillSearchRequest{Query: "  dashboard  "})
	if err != nil {
		t.Fatalf("valid query rejected: %v", err)
	}
	if got.Query != "dashboard" || got.Limit != 5 {
		t.Fatalf("unexpected normalize: %+v", got)
	}
	_, err = normalizeSkillSearch(SkillSearchRequest{Query: "x", Limit: 99})
	if err != ErrInvalidSkillLimit {
		t.Fatalf("bad limit = %v", err)
	}
}

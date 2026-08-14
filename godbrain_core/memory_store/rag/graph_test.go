package rag

import "testing"

func TestGraphLabelTruncatesAndFallsBack(t *testing.T) {
	if got := graphLabel("", "claim:auth"); got != "claim:auth" {
		t.Fatalf("empty content fallback = %q", got)
	}
	if got := graphLabel("  Bearer   authentication  ", "x"); got != "Bearer authentication" {
		t.Fatalf("whitespace collapse = %q", got)
	}
	long := ""
	for i := 0; i < MaxGraphLabel+10; i++ {
		long += "a"
	}
	if got := graphLabel(long, "x"); len([]rune(got)) != MaxGraphLabel {
		t.Fatalf("truncated length = %d", len([]rune(got)))
	}
}

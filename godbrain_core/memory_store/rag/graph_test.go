package rag

import "testing"

func TestStarLinksUsesDeterministicHubAndBudget(t *testing.T) {
	groups := map[string][]string{
		"src-b": {"n3", "n1", "n2"},
		"src-a": {"n9", "n8"},
	}
	links, truncated := starLinks(groups, LinkKindSameSource, 10)
	if truncated {
		t.Fatal("budget 10 should hold these links")
	}
	if len(links) != 3 {
		t.Fatalf("got %d links, want 3: %#v", len(links), links)
	}
	if links[0] != (GraphLink{Source: "n8", Target: "n9", Kind: LinkKindSameSource}) {
		t.Fatalf("first group was not src-a hub n8: %#v", links[0])
	}
	if links[1].Source != "n1" || links[1].Target != "n2" || links[2].Target != "n3" {
		t.Fatalf("src-b star was not n1->n2,n3: %#v", links)
	}

	capped, hit := starLinks(groups, LinkKindSameSource, 1)
	if !hit || len(capped) != 1 {
		t.Fatalf("budget 1 = %d links truncated=%v", len(capped), hit)
	}
}

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

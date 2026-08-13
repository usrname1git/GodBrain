package main

import "testing"

func TestServicePort(t *testing.T) {
	if port, err := servicePort(""); err != nil || port != 8084 {
		t.Fatalf("unexpected default port=%d err=%v", port, err)
	}
	for _, value := range []string{"0", "65536", "-1", "8084x"} {
		if _, err := servicePort(value); err == nil {
			t.Fatalf("expected invalid port %q to fail", value)
		}
	}
	if port, err := servicePort("18084"); err != nil || port != 18084 {
		t.Fatalf("unexpected configured port=%d err=%v", port, err)
	}
}

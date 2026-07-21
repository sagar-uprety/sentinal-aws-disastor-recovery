package db

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadTargets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "targets.json")
	if err := os.WriteFile(path, []byte(`{"targets":["https://example.com","http://example.org"]}`), 0600); err != nil {
		t.Fatalf("write targets file: %v", err)
	}

	targets, err := LoadTargets(path)
	if err != nil {
		t.Fatalf("load targets: %v", err)
	}
	if len(targets) != 2 || targets[0] != "https://example.com" {
		t.Fatalf("targets = %v, want configured URLs", targets)
	}
}

func TestLoadTargetsRejectsInvalidURL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "targets.json")
	if err := os.WriteFile(path, []byte(`{"targets":["ftp://example.com"]}`), 0600); err != nil {
		t.Fatalf("write targets file: %v", err)
	}

	if _, err := LoadTargets(path); err == nil {
		t.Fatal("expected invalid target URL error")
	}
}

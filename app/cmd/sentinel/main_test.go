package main

import (
	"strings"
	"testing"
)

// clearDatabaseEnv isolates database configuration test cases.
func clearDatabaseEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{"DATABASE_URL", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"} {
		t.Setenv(name, "")
	}
}

// TestLoadConfigWithDatabaseURL verifies local DATABASE_URL configuration.
func TestLoadConfigWithDatabaseURL(t *testing.T) {
	clearDatabaseEnv(t)
	want := "postgres://postgres:postgres@localhost:5432/sentinel?sslmode=disable"
	t.Setenv("DATABASE_URL", want)

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.databaseURL != want {
		t.Fatalf("database URL = %q, want %q", cfg.databaseURL, want)
	}
}

// TestLoadConfigWithDatabaseVariables verifies ECS-style split database configuration.
func TestLoadConfigWithDatabaseVariables(t *testing.T) {
	clearDatabaseEnv(t)
	t.Setenv("DB_HOST", "db")
	t.Setenv("DB_PORT", "5432")
	t.Setenv("DB_NAME", "sentinel")
	t.Setenv("DB_USER", "sentinel")
	t.Setenv("DB_PASSWORD", "p@ss/word")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	want := "postgres://sentinel:p%40ss%2Fword@db:5432/sentinel?sslmode=disable"
	if cfg.databaseURL != want {
		t.Fatalf("database URL = %q, want %q", cfg.databaseURL, want)
	}
}

// TestLoadConfigRejectsMixedDatabaseConfiguration verifies configuration paths cannot be combined.
func TestLoadConfigRejectsMixedDatabaseConfiguration(t *testing.T) {
	clearDatabaseEnv(t)
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("DB_HOST", "db")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("error = %v, want mutual exclusion error", err)
	}
}

// TestLoadConfigRejectsIncompleteDatabaseVariables verifies every split database value is required.
func TestLoadConfigRejectsIncompleteDatabaseVariables(t *testing.T) {
	clearDatabaseEnv(t)
	t.Setenv("DB_HOST", "db")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "database configuration missing") {
		t.Fatalf("error = %v, want missing configuration error", err)
	}
}

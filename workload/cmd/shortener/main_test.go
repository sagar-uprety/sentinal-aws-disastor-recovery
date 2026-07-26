package main

import (
	"strings"
	"testing"
)

func clearEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{"DATABASE_URL", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "LINK_CREATE_TOKEN", "PORT"} {
		t.Setenv(name, "")
	}
}

func TestLoadConfig(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("DATABASE_URL", "postgres://localhost/shortener")
	t.Setenv("LINK_CREATE_TOKEN", "development-token")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.port != 8080 || cfg.databaseURL == "" || cfg.createToken == "" {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}

func TestLoadConfigRejectsShortToken(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("DATABASE_URL", "postgres://localhost/shortener")
	t.Setenv("LINK_CREATE_TOKEN", "short")
	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "at least 16") {
		t.Fatalf("error = %v, want token length error", err)
	}
}

func TestDatabaseConnectionURLFromParts(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("DB_HOST", "database")
	t.Setenv("DB_PORT", "5432")
	t.Setenv("DB_NAME", "shortener")
	t.Setenv("DB_USER", "shortener")
	t.Setenv("DB_PASSWORD", "p@ss/word")
	got, err := databaseConnectionURL()
	if err != nil {
		t.Fatalf("database URL: %v", err)
	}
	want := "postgres://shortener:p%40ss%2Fword@database:5432/shortener?sslmode=require"
	if got != want {
		t.Fatalf("database URL = %q, want %q", got, want)
	}
}

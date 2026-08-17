package main

import (
	"strings"
	"testing"
)

// resets every config-relevant env var so tests don't leak state between each other; t.Setenv auto-restores the original value after the test.
func clearEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"MONITORED_URL", "DYNAMODB_TABLE", "AWS_REGION", "PORT", "CHECK_INTERVAL_SECONDS",
		"PROD_AWS_REGION", "PROD_ECS_CLUSTER", "PROD_ECS_SERVICE", "PROD_DB_IDENTIFIER",
		"DR_AWS_REGION", "DR_ECS_CLUSTER", "DR_ECS_SERVICE", "DR_DB_IDENTIFIER",
		"TOPOLOGY_MOCK_FILE",
	} {
		t.Setenv(name, "")
	}
}

func TestLoadConfigLocalDefaults(t *testing.T) {
	clearEnvironment(t)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.monitoredURL != "http://localhost:8081/healthz" || cfg.dynamoTable != "" || len(cfg.regions) != 0 {
		t.Fatalf("unexpected local config: %#v", cfg)
	}
}

func TestLoadConfigProduction(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("MONITORED_URL", "https://workload.example.com/healthz")
	t.Setenv("DYNAMODB_TABLE", "checks")
	t.Setenv("AWS_REGION", "eu-west-1")
	for key, value := range map[string]string{
		"PROD_AWS_REGION": "eu-west-1", "PROD_ECS_CLUSTER": "prod", "PROD_ECS_SERVICE": "workload", "PROD_DB_IDENTIFIER": "prod-db",
		"DR_AWS_REGION": "eu-central-1", "DR_ECS_CLUSTER": "dr", "DR_ECS_SERVICE": "workload", "DR_DB_IDENTIFIER": "dr-db",
	} {
		t.Setenv(key, value)
	}
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.dynamoTable != "checks" || cfg.awsRegion != "eu-west-1" || len(cfg.regions) != 2 {
		t.Fatalf("unexpected production config: %#v", cfg)
	}
}

func TestLoadConfigRejectsInvalidTarget(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("MONITORED_URL", "ftp://example.com/healthz")
	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "MONITORED_URL") {
		t.Fatalf("error = %v, want monitored URL error", err)
	}
}

func TestLoadConfigRequiresDynamoRegion(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("DYNAMODB_TABLE", "checks")
	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "AWS_REGION") {
		t.Fatalf("error = %v, want AWS region error", err)
	}
}

func TestLoadConfigRejectsPartialTopology(t *testing.T) {
	clearEnvironment(t)
	t.Setenv("PROD_AWS_REGION", "eu-west-1")
	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "PROD topology") {
		t.Fatalf("error = %v, want topology error", err)
	}
}

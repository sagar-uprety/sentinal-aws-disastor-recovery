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
		"PRIMARY_AWS_REGION", "PRIMARY_ECS_CLUSTER", "PRIMARY_ECS_SERVICE", "PRIMARY_DB_IDENTIFIER",
		"SECONDARY_AWS_REGION", "SECONDARY_ECS_CLUSTER", "SECONDARY_ECS_SERVICE", "SECONDARY_DB_IDENTIFIER",
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
		"PRIMARY_AWS_REGION": "eu-west-1", "PRIMARY_ECS_CLUSTER": "primary", "PRIMARY_ECS_SERVICE": "workload", "PRIMARY_DB_IDENTIFIER": "primary-db",
		"SECONDARY_AWS_REGION": "eu-central-1", "SECONDARY_ECS_CLUSTER": "secondary", "SECONDARY_ECS_SERVICE": "workload", "SECONDARY_DB_IDENTIFIER": "secondary-db",
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
	t.Setenv("PRIMARY_AWS_REGION", "eu-west-1")
	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "PRIMARY topology") {
		t.Fatalf("error = %v, want topology error", err)
	}
}

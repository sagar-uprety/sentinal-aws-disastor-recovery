package store

import (
	"context"
	"time"
)

// how long a DynamoDB-backed store keeps a check row before its TTL expires it.
const Retention = 30 * 24 * time.Hour

type Target struct {
	URL string `json:"url"`
}

type Check struct {
	CheckedAt  time.Time `json:"checked_at" dynamodbav:"checked_at"`
	StatusCode *int      `json:"status_code" dynamodbav:"status_code,omitempty"`
	TargetURL  string    `json:"target_url" dynamodbav:"target_url"`
	ResponseMs int       `json:"response_ms" dynamodbav:"response_ms"`
	IsUp       bool      `json:"is_up" dynamodbav:"is_up"`
}

type TargetStatus struct {
	LastChecked    time.Time `json:"last_checked"`
	StatusCode     *int      `json:"status_code"`
	URL            string    `json:"url"`
	ResponseMs     int       `json:"response_ms"`
	UptimePct      float64   `json:"uptime_pct_24h"`
	SampleCount24h int       `json:"sample_count_24h"`
	IsUp           bool      `json:"is_up"`
}

// backs the checker/HTTP handlers; implemented by both the in-memory and DynamoDB stores.
type Store interface {
	ListTargets(context.Context) ([]Target, error)
	RecordCheck(context.Context, Check) error
	// computes uptime using only checks at or after the given cutoff time.
	LatestStatuses(context.Context, time.Time) ([]TargetStatus, error)
	History(context.Context, string, int) ([]Check, error)
	Health(context.Context) error
}

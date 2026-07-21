package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"time"

	_ "github.com/lib/pq"
)

type TargetRow struct {
	URL string
	ID  int
}

type CheckRow struct {
	CheckedAt  time.Time `json:"checked_at"`
	StatusCode *int      `json:"status_code"`
	TargetURL  string    `json:"target_url"`
	ResponseMs int       `json:"response_ms"`
	IsUp       bool      `json:"is_up"`
}

type TargetStatus struct {
	LastChecked time.Time `json:"last_checked"`
	StatusCode  *int      `json:"status_code"`
	URL         string    `json:"url"`
	ResponseMs  int       `json:"response_ms"`
	UptimePct   float64   `json:"uptime_pct_24h"`
	IsUp        bool      `json:"is_up"`
}

// Creates and verifies a bounded PostgreSQL connection pool.
func Open(ctx context.Context, dsn string) (*sql.DB, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}
	return db, nil
}

// Applies the idempotent application schema.
func Migrate(ctx context.Context, db *sql.DB) error {
	queries := []string{
		`CREATE TABLE IF NOT EXISTS targets (
			id SERIAL PRIMARY KEY,
			url TEXT UNIQUE NOT NULL
		)`,
		// Keep target URLs denormalized so history survives target removal.
		`CREATE TABLE IF NOT EXISTS checks (
			id BIGSERIAL PRIMARY KEY,
			target_url TEXT NOT NULL,
			status_code INT,
			response_ms INT,
			is_up BOOLEAN NOT NULL,
			checked_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_checks_target_time
		 ON checks (target_url, checked_at DESC)`,
	}
	for _, q := range queries {
		if _, err := db.ExecContext(ctx, q); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	slog.Info("migrations complete")
	return nil
}

// Loads target URLs from a version-controlled JSON file.
func LoadTargets(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open targets file: %w", err)
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			slog.Error("close targets file failed", "error", closeErr)
		}
	}()

	var config struct {
		Targets []string `json:"targets"`
	}
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return nil, fmt.Errorf("decode targets file: %w", err)
	}
	if len(config.Targets) == 0 {
		return nil, fmt.Errorf("targets file must contain at least one target")
	}
	for _, target := range config.Targets {
		parsed, err := url.ParseRequestURI(target)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return nil, fmt.Errorf("invalid target URL %q", target)
		}
	}
	return config.Targets, nil
}

// Inserts configured targets once.
func SeedTargets(ctx context.Context, db *sql.DB, targets []string) error {
	return SeedTargetsFromList(ctx, db, targets)
}

// Inserts the given URLs as targets, ignoring duplicates.
func SeedTargetsFromList(ctx context.Context, db *sql.DB, urls []string) error {
	for _, url := range urls {
		_, err := db.ExecContext(ctx, `INSERT INTO targets (url) VALUES ($1) ON CONFLICT (url) DO NOTHING`, url)
		if err != nil {
			return fmt.Errorf("seed target %s: %w", url, err)
		}
	}
	return nil
}

// Returns configured targets in insertion order.
func ListTargets(ctx context.Context, db *sql.DB) ([]TargetRow, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, url FROM targets ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("list targets: %w", err)
	}
	defer func() {
		if cerr := rows.Close(); cerr != nil {
			slog.Error("close rows failed", "error", cerr)
		}
	}()

	var targets []TargetRow
	for rows.Next() {
		var t TargetRow
		if err := rows.Scan(&t.ID, &t.URL); err != nil {
			return nil, fmt.Errorf("scan target: %w", err)
		}
		targets = append(targets, t)
	}
	return targets, rows.Err()
}

// Persists one uptime check and logs write failures.
func RecordCheck(ctx context.Context, db *sql.DB, targetURL string, statusCode *int, responseMs int, isUp bool) {
	_, err := db.ExecContext(ctx,
		`INSERT INTO checks (target_url, status_code, response_ms, is_up, checked_at)
		 VALUES ($1, $2, $3, $4, NOW())`,
		targetURL, statusCode, responseMs, isUp,
	)
	if err != nil {
		slog.Error("failed to record check", "target", targetURL, "error", err)
	}
}

// Returns each target's latest check and 24-hour uptime.
func GetLatestPerTarget(ctx context.Context, db *sql.DB) ([]TargetStatus, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT DISTINCT ON (c.target_url)
			c.target_url, c.is_up, c.status_code, c.response_ms, c.checked_at,
			COALESCE(u.uptime, 0) AS uptime_pct
		FROM checks c
		INNER JOIN targets t ON t.url = c.target_url
		LEFT JOIN (
			SELECT target_url,
				ROUND(100.0 * SUM(CASE WHEN is_up THEN 1 ELSE 0 END) / COUNT(*), 1) AS uptime
			FROM checks
			WHERE checked_at > NOW() - INTERVAL '24 hours'
			GROUP BY target_url
		) u ON u.target_url = c.target_url
		ORDER BY c.target_url, c.checked_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("latest per target: %w", err)
	}
	defer func() {
		if cerr := rows.Close(); cerr != nil {
			slog.Error("close rows failed", "error", cerr)
		}
	}()

	var results []TargetStatus
	for rows.Next() {
		var ts TargetStatus
		if err := rows.Scan(&ts.URL, &ts.IsUp, &ts.StatusCode, &ts.ResponseMs, &ts.LastChecked, &ts.UptimePct); err != nil {
			return nil, fmt.Errorf("scan status: %w", err)
		}
		results = append(results, ts)
	}
	return results, rows.Err()
}

// Returns recent checks for one exact target URL.
func GetHistory(ctx context.Context, db *sql.DB, target string, limit int) ([]CheckRow, error) {
	// Exact matching prevents targets with shared hosts or prefixes from colliding.
	rows, err := db.QueryContext(ctx, `
		SELECT target_url, status_code, response_ms, is_up, checked_at
		FROM checks
		WHERE target_url = $1
		ORDER BY checked_at DESC
		LIMIT $2
	`, target, limit)
	if err != nil {
		return nil, fmt.Errorf("get history: %w", err)
	}
	defer func() {
		if cerr := rows.Close(); cerr != nil {
			slog.Error("close rows failed", "error", cerr)
		}
	}()

	var checks []CheckRow
	for rows.Next() {
		var c CheckRow
		if err := rows.Scan(&c.TargetURL, &c.StatusCode, &c.ResponseMs, &c.IsUp, &c.CheckedAt); err != nil {
			return nil, fmt.Errorf("scan check: %w", err)
		}
		checks = append(checks, c)
	}
	return checks, rows.Err()
}

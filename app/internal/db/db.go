package db

import (
	"database/sql"
	"fmt"
	"log/slog"
	"time"

	_ "github.com/lib/pq"
)

type TargetRow struct {
	ID  int
	URL string
}

type CheckRow struct {
	TargetURL  string    `json:"target_url"`
	StatusCode *int      `json:"status_code"`
	ResponseMs int       `json:"response_ms"`
	IsUp       bool      `json:"is_up"`
	CheckedAt  time.Time `json:"checked_at"`
}

type TargetStatus struct {
	URL         string    `json:"url"`
	IsUp        bool      `json:"is_up"`
	StatusCode  *int      `json:"status_code"`
	ResponseMs  int       `json:"response_ms"`
	LastChecked time.Time `json:"last_checked"`
	UptimePct   float64   `json:"uptime_pct_24h"`
}

// Creates and verifies a bounded PostgreSQL connection pool.
func Open(dsn string) (*sql.DB, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}
	return db, nil
}

// Applies the idempotent application schema.
func Migrate(db *sql.DB) error {
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
		if _, err := db.Exec(q); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	slog.Info("migrations complete")
	return nil
}

// Inserts default and optional self-check targets once.
func SeedTargets(db *sql.DB, selfURL string) error {
	defaults := []string{
		"https://www.google.com",
		"https://github.com",
	}
	if selfURL != "" {
		defaults = append(defaults, selfURL)
	}
	return SeedTargetsFromList(db, defaults)
}

// Inserts the given URLs as targets, ignoring duplicates.
func SeedTargetsFromList(db *sql.DB, urls []string) error {
	for _, url := range urls {
		_, err := db.Exec(`INSERT INTO targets (url) VALUES ($1) ON CONFLICT (url) DO NOTHING`, url)
		if err != nil {
			return fmt.Errorf("seed target %s: %w", url, err)
		}
	}
	return nil
}

// Returns configured targets in insertion order.
func ListTargets(db *sql.DB) ([]TargetRow, error) {
	rows, err := db.Query(`SELECT id, url FROM targets ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("list targets: %w", err)
	}
	defer rows.Close()

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
func RecordCheck(db *sql.DB, targetURL string, statusCode *int, responseMs int, isUp bool) {
	_, err := db.Exec(
		`INSERT INTO checks (target_url, status_code, response_ms, is_up, checked_at)
		 VALUES ($1, $2, $3, $4, NOW())`,
		targetURL, statusCode, responseMs, isUp,
	)
	if err != nil {
		slog.Error("failed to record check", "target", targetURL, "error", err)
	}
}

// Returns each target's latest check and 24-hour uptime.
func GetLatestPerTarget(db *sql.DB) ([]TargetStatus, error) {
	rows, err := db.Query(`
		SELECT DISTINCT ON (c.target_url)
			c.target_url, c.is_up, c.status_code, c.response_ms, c.checked_at,
			COALESCE(u.uptime, 0) AS uptime_pct
		FROM checks c
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
	defer rows.Close()

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
func GetHistory(db *sql.DB, target string, limit int) ([]CheckRow, error) {
	// Exact matching prevents targets with shared hosts or prefixes from colliding.
	rows, err := db.Query(`
		SELECT target_url, status_code, response_ms, is_up, checked_at
		FROM checks
		WHERE target_url = $1
		ORDER BY checked_at DESC
		LIMIT $2
	`, target, limit)
	if err != nil {
		return nil, fmt.Errorf("get history: %w", err)
	}
	defer rows.Close()

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

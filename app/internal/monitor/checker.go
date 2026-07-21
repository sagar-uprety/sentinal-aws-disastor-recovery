package monitor

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"time"

	"sentinel-aws-dr/app/internal/db"
)

type Checker struct {
	database    *sql.DB
	client      *http.Client
	interval    time.Duration
	httpTimeout time.Duration
}

const (
	checkerLockQuery   = `SELECT pg_try_advisory_lock(hashtext('sentinel-aws-dr'), hashtext('monitor-checker'))`
	checkerUnlockQuery = `SELECT pg_advisory_unlock(hashtext('sentinel-aws-dr'), hashtext('monitor-checker'))`
)

// Creates an HTTP checker with bounded request duration and no redirect following.
func NewChecker(database *sql.DB, interval, timeout time.Duration) *Checker {
	return &Checker{
		database:    database,
		interval:    interval,
		httpTimeout: timeout,
		client: &http.Client{
			Timeout: timeout,
			// A redirect proves reachability and should retain its original status code.
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// Elects one checker across replicas and retries leadership until cancellation.
func (c *Checker) Run(ctx context.Context) {
	slog.Info("checker election started", "interval", c.interval.Seconds())
	retry := time.NewTicker(c.interval)
	defer retry.Stop()

	for {
		conn, err := c.database.Conn(ctx)
		if err == nil {
			var leader bool
			err = conn.QueryRowContext(ctx, checkerLockQuery).Scan(&leader)
			if err == nil && leader {
				slog.Info("checker leadership acquired")
				c.runAsLeader(ctx, conn)
				unlockCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				var unlocked bool
				unlockErr := conn.QueryRowContext(unlockCtx, checkerUnlockQuery).Scan(&unlocked)
				cancel()
				if unlockErr != nil && ctx.Err() == nil {
					slog.Error("checker: leadership release failed", "error", unlockErr)
				}
			}
			if closeErr := conn.Close(); closeErr != nil {
				slog.Error("checker: close leadership connection failed", "error", closeErr)
			}
		}
		if err != nil && ctx.Err() == nil {
			slog.Error("checker: leadership election failed", "error", err)
		}

		select {
		case <-ctx.Done():
			slog.Info("checker stopped")
			return
		case <-retry.C:
		}
	}
}

// Runs checks while the dedicated advisory-lock session remains healthy.
func (c *Checker) runAsLeader(ctx context.Context, conn *sql.Conn) {
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	for {
		if err := conn.PingContext(ctx); err != nil {
			if ctx.Err() == nil {
				slog.Error("checker: leadership connection lost", "error", err)
			}
			return
		}
		c.runOnce(ctx)

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Loads the current target set and checks each target once.
func (c *Checker) runOnce(ctx context.Context) {
	targets, err := db.ListTargets(ctx, c.database)
	if err != nil {
		slog.Error("checker: failed to list targets", "error", err)
		return
	}
	for _, t := range targets {
		c.checkTarget(ctx, t)
	}
}

type checkResult struct {
	err        error
	statusCode *int
	url        string
	responseMs int
	isUp       bool
}

// Measures one request and classifies 2xx and 3xx responses as reachable.
func httpCheck(ctx context.Context, client *http.Client, url string) checkResult {
	start := time.Now()
	cr := checkResult{url: url}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		cr.err = err
		cr.responseMs = int(time.Since(start).Milliseconds())
		return cr
	}

	resp, err := client.Do(req)
	cr.responseMs = int(time.Since(start).Milliseconds())

	if err != nil {
		cr.err = err
	} else {
		code := resp.StatusCode
		cr.statusCode = &code
		if cerr := resp.Body.Close(); cerr != nil {
			slog.Error("close response body failed", "error", cerr)
		}
		if code >= 200 && code < 400 {
			cr.isUp = true
		}
	}
	return cr
}

// Records one check result in PostgreSQL and writes a structured log entry.
func (c *Checker) checkTarget(ctx context.Context, t db.TargetRow) {
	cr := httpCheck(ctx, c.client, t.URL)

	attrs := []any{
		"target", cr.url,
		"status_code", cr.statusCode,
		"response_ms", cr.responseMs,
		"is_up", cr.isUp,
	}
	if cr.err != nil {
		attrs = append(attrs, "error", cr.err)
	}
	slog.Info("check result", attrs...)

	db.RecordCheck(ctx, c.database, cr.url, cr.statusCode, cr.responseMs, cr.isUp)
}

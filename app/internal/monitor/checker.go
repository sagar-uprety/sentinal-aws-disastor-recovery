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

// Checks all targets immediately and then at each interval until cancellation.
func (c *Checker) Run(ctx context.Context) {
	slog.Info("checker started", "interval", c.interval.Seconds())
	// Run immediately so a new deployment does not wait one interval for data.
	c.runOnce(ctx)
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("checker stopped")
			return
		case <-ticker.C:
			c.runOnce(ctx)
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
		cr.responseMs = int(time.Since(start).Milliseconds())
		return cr
	}

	resp, err := client.Do(req)
	cr.responseMs = int(time.Since(start).Milliseconds())

	if err == nil {
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

	slog.Info("check result",
		"target", cr.url,
		"status_code", cr.statusCode,
		"response_ms", cr.responseMs,
		"is_up", cr.isUp,
	)

	db.RecordCheck(ctx, c.database, cr.url, cr.statusCode, cr.responseMs, cr.isUp)
}

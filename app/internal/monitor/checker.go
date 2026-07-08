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
	metrics     *Metrics
	interval    time.Duration
	httpTimeout time.Duration
	selfURL     string
	client      *http.Client
}

func NewChecker(database *sql.DB, m *Metrics, interval, timeout time.Duration, selfURL string) *Checker {
	return &Checker{
		database:    database,
		metrics:     m,
		interval:    interval,
		httpTimeout: timeout,
		selfURL:     selfURL,
		client: &http.Client{
			Timeout: timeout,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

func (c *Checker) Run(ctx context.Context) {
	slog.Info("checker started", "interval", c.interval.Seconds())
	c.runOnce()
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("checker stopped")
			return
		case <-ticker.C:
			c.runOnce()
		}
	}
}

func (c *Checker) runOnce() {
	targets, err := db.ListTargets(c.database)
	if err != nil {
		slog.Error("checker: failed to list targets", "error", err)
		return
	}
	for _, t := range targets {
		c.checkTarget(t)
	}
}

type checkResult struct {
	url        string
	statusCode *int
	responseMs int
	isUp       bool
}

func httpCheck(client *http.Client, url string) checkResult {
	start := time.Now()
	resp, err := client.Get(url)
	elapsed := time.Since(start)
	cr := checkResult{url: url, responseMs: int(elapsed.Milliseconds())}

	if err == nil {
		code := resp.StatusCode
		cr.statusCode = &code
		resp.Body.Close()
		if code >= 200 && code < 400 {
			cr.isUp = true
		}
	}
	return cr
}

func (c *Checker) checkTarget(t db.TargetRow) {
	cr := httpCheck(c.client, t.URL)

	slog.Info("check result",
		"target", cr.url,
		"status_code", cr.statusCode,
		"response_ms", cr.responseMs,
		"is_up", cr.isUp,
	)

	db.RecordCheck(c.database, cr.url, cr.statusCode, cr.responseMs, cr.isUp)
	c.metrics.Observe(context.Background(), cr.url, cr.responseMs, cr.isUp)
}

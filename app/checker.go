package main

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"time"
)

type checker struct {
	db          *sql.DB
	metrics     *metrics
	interval    time.Duration
	httpTimeout time.Duration
	selfURL     string
	client      *http.Client
}

func newChecker(db *sql.DB, m *metrics, interval, timeout time.Duration, selfURL string) *checker {
	return &checker{
		db:          db,
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

func (c *checker) run(ctx context.Context) {
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

func (c *checker) runOnce() {
	targets, err := listTargets(c.db)
	if err != nil {
		slog.Error("checker: failed to list targets", "error", err)
		return
	}
	for _, t := range targets {
		c.checkTarget(t)
	}
	slog.Debug("check cycle complete", "targets", len(targets))
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

func (c *checker) checkTarget(t targetRow) {
	cr := httpCheck(c.client, t.URL)

	slog.Info("check result",
		"target", cr.url,
		"status_code", cr.statusCode,
		"response_ms", cr.responseMs,
		"is_up", cr.isUp,
	)

	recordCheck(c.db, cr.url, cr.statusCode, cr.responseMs, cr.isUp)
	c.metrics.observe(context.Background(), cr.url, cr.responseMs, cr.isUp)
}

package monitor

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"aws-pilotlight-multi-region-dr/apps/monitor/internal/store"
)

type Checker struct {
	store    store.Store
	client   *http.Client
	now      func() time.Time
	target   string
	interval time.Duration
}

func NewChecker(dataStore store.Store, target string, interval, timeout time.Duration) *Checker {
	return &Checker{
		store: dataStore, target: target, interval: interval, now: time.Now,
		client: &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			// The target's DNS answer changes on regional failover (that's the
			// whole point of this checker). A pooled keep-alive connection
			// never re-resolves DNS as long as it keeps getting reused, and at
			// a 30s check interval it never sits idle long enough to expire
			// from Go's default 90s pool -- so the checker would keep talking
			// to the pre-failover region indefinitely. Force a fresh
			// connection (and thus fresh DNS lookup) on every check instead.
			Transport: &http.Transport{DisableKeepAlives: true},
		},
	}
}

func (c *Checker) Run(ctx context.Context) {
	slog.Info("checker started", "target", c.target, "interval_seconds", c.interval.Seconds())
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

func (c *Checker) runOnce(ctx context.Context) {
	result := httpCheck(ctx, c.client, c.target)
	attrs := []any{"target", result.url, "status_code", result.statusCode, "response_ms", result.responseMs, "is_up", result.isUp}
	if result.err != nil {
		attrs = append(attrs, "error", result.err)
	}
	slog.Info("check result", attrs...)
	if err := c.store.RecordCheck(ctx, store.Check{
		CheckedAt: c.now().UTC(), StatusCode: result.statusCode, TargetURL: result.url,
		ResponseMs: result.responseMs, IsUp: result.isUp,
	}); err != nil {
		slog.Error("checker: record failed", "target", result.url, "error", err)
	}
}

type checkResult struct {
	err        error
	statusCode *int
	url        string
	responseMs int
	isUp       bool
}

func httpCheck(ctx context.Context, client *http.Client, url string) checkResult {
	start := time.Now()
	result := checkResult{url: url}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		result.err = err
		result.responseMs = int(time.Since(start).Milliseconds())
		return result
	}
	resp, err := client.Do(req)
	result.responseMs = int(time.Since(start).Milliseconds())
	if err != nil {
		result.err = err
		return result
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			slog.Error("close response body failed", "error", err)
		}
	}()
	result.statusCode = &resp.StatusCode
	result.isUp = resp.StatusCode >= 200 && resp.StatusCode < 400
	return result
}

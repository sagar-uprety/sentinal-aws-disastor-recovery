package sentry

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"aws-pilotlight-multi-region-dr/apps/sentry/internal/store"
)

type Checker struct {
	store    store.Store
	client   *http.Client
	now      func() time.Time
	target   string
	interval time.Duration
}

// builds a Checker with keep-alives disabled; see the Transport comment below.
func NewChecker(dataStore store.Store, target string, interval, timeout time.Duration) *Checker {
	return &Checker{
		store: dataStore, target: target, interval: interval, now: time.Now,
		client: &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			// the target's DNS answer changes on failover, but a pooled connection never re-resolves,
			// and a 30s interval never idles out of Go's 90s pool: it would poll the old region forever.
			Transport: &http.Transport{DisableKeepAlives: true},
		},
	}
}

// runs an immediate check, then repeats on the configured interval until ctx is canceled.
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

// performs one check and persists it; a store failure is logged, never returned,
// because the checker has to survive its own storage being unavailable.
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

// issues a single GET, timing it regardless of outcome; isUp is true only for 2xx/3xx responses.
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

package monitor

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"aws-pilotlight-multi-region-dr/apps/monitor/internal/store"
)

// in-memory stand-in for store.Store; records what handlers/checker do to it without touching DynamoDB.
type fakeStore struct {
	health   error
	targets  []store.Target
	checks   []store.Check
	statuses []store.TargetStatus
}

func (f *fakeStore) ListTargets(context.Context) ([]store.Target, error) { return f.targets, nil }
func (f *fakeStore) RecordCheck(_ context.Context, check store.Check) error {
	f.checks = append(f.checks, check)
	return nil
}
func (f *fakeStore) LatestStatuses(context.Context, time.Time) ([]store.TargetStatus, error) {
	return f.statuses, nil
}
func (f *fakeStore) History(_ context.Context, target string, limit int) ([]store.Check, error) {
	result := make([]store.Check, 0, limit)
	for _, check := range f.checks {
		if check.TargetURL == target && len(result) < limit {
			result = append(result, check)
		}
	}
	return result, nil
}
func (f *fakeStore) Health(context.Context) error { return f.health }

func TestHTTPCheckClassifiesResponses(t *testing.T) {
	for _, test := range []struct {
		name string
		code int
		up   bool
	}{{"success", http.StatusOK, true}, {"redirect", http.StatusMovedPermanently, true}, {"failure", http.StatusInternalServerError, false}} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(test.code) }))
			defer server.Close()
			client := &http.Client{Timeout: time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
			result := httpCheck(context.Background(), client, server.URL)
			if result.err != nil || result.statusCode == nil || *result.statusCode != test.code || result.isUp != test.up {
				t.Fatalf("unexpected result: %#v", result)
			}
		})
	}
}

// client timeout (1ms) is far shorter than the server's fixed 100ms delay, so this reliably times out rather than racing.
func TestHTTPCheckTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(100 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	result := httpCheck(context.Background(), &http.Client{Timeout: time.Millisecond}, server.URL)
	if result.err == nil || result.statusCode != nil || result.isUp {
		t.Fatalf("unexpected timeout result: %#v", result)
	}
}

func TestCheckerRecordsConfiguredTarget(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer server.Close()
	dataStore := &fakeStore{}
	checker := NewChecker(dataStore, server.URL, time.Minute, time.Second)
	// overrides the checker's clock so CheckedAt is deterministic instead of time.Now().
	wantTime := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	checker.now = func() time.Time { return wantTime }
	checker.runOnce(context.Background())
	if len(dataStore.checks) != 1 || dataStore.checks[0].TargetURL != server.URL || !dataStore.checks[0].CheckedAt.Equal(wantTime) {
		t.Fatalf("recorded checks = %#v", dataStore.checks)
	}
}

// smoke-tests every read handler against one shared fake store: each must return 200 with a valid JSON body.
func TestHandlers(t *testing.T) {
	now := time.Now().UTC()
	dataStore := &fakeStore{
		targets:  []store.Target{{URL: "https://example.com/healthz"}},
		statuses: []store.TargetStatus{{URL: "https://example.com/healthz", IsUp: true, LastChecked: now, UptimePct: 100}},
		checks:   []store.Check{{TargetURL: "https://example.com/healthz", IsUp: true, CheckedAt: now}},
	}
	for _, test := range []struct {
		handler http.HandlerFunc
		path    string
	}{
		{HandleHealthz(dataStore), "/healthz"},
		{HandleTargets(dataStore), "/targets"},
		{HandleStatus(dataStore), "/status"},
		{HandleHistory(dataStore), "/history?target=https://example.com/healthz&limit=1"},
	} {
		recorder := httptest.NewRecorder()
		test.handler(recorder, httptest.NewRequestWithContext(context.Background(), http.MethodGet, test.path, nil))
		if recorder.Code != http.StatusOK || !json.Valid(recorder.Body.Bytes()) {
			t.Errorf("%s returned %d: %s", test.path, recorder.Code, recorder.Body.String())
		}
	}
}

func TestHealthHandlerUnavailable(t *testing.T) {
	recorder := httptest.NewRecorder()
	HandleHealthz(&fakeStore{health: errors.New("unavailable")})(recorder, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/healthz", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", recorder.Code)
	}
}

func TestHistoryRequiresTarget(t *testing.T) {
	recorder := httptest.NewRecorder()
	HandleHistory(&fakeStore{})(recorder, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/history", nil))
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", recorder.Code)
	}
}

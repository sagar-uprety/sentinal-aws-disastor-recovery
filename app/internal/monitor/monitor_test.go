package monitor

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	_ "github.com/lib/pq"

	"sentinel-aws-dr/app/internal/db"
)

// opens, resets, migrates, and seeds the local integration database.
func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	ctx := context.Background()
	testDB, err := sql.Open("postgres", "postgres://postgres:postgres@localhost:5432/sentinel?sslmode=disable")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := testDB.PingContext(ctx); err != nil {
		t.Fatalf("db ping: %v (is Postgres running? try: docker compose up -d db)", err)
	}
	if err := db.Migrate(ctx, testDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := testDB.ExecContext(ctx, "TRUNCATE targets, checks RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	if err := db.SeedTargets(ctx, testDB, ""); err != nil {
		t.Fatalf("seed targets: %v", err)
	}
	return testDB
}

func closeTestDB(t *testing.T, testDB *sql.DB) {
	t.Helper()
	if err := testDB.Close(); err != nil {
		t.Errorf("close db: %v", err)
	}
}

// verifies successful responses are reported as up.
func TestHTTPCheckUp(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write([]byte("ok")); err != nil {
			t.Fatalf("write response: %v", err)
		}
	}))
	defer server.Close()

	client := &http.Client{Timeout: 5 * time.Second}
	cr := httpCheck(context.Background(), client, server.URL)

	if cr.statusCode == nil || *cr.statusCode != 200 {
		t.Errorf("expected status 200, got %v", cr.statusCode)
	}
	if !cr.isUp {
		t.Error("expected isUp = true")
	}
}

// verifies server errors are reported as down.
func TestHTTPCheckDown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		if _, err := w.Write([]byte("error")); err != nil {
			t.Fatalf("write response: %v", err)
		}
	}))
	defer server.Close()

	client := &http.Client{Timeout: 5 * time.Second}
	cr := httpCheck(context.Background(), client, server.URL)

	if cr.statusCode == nil || *cr.statusCode != 500 {
		t.Errorf("expected status 500, got %v", cr.statusCode)
	}
	if cr.isUp {
		t.Error("expected isUp = false for 5xx")
	}
}

// verifies timed-out requests have no status code and are down.
func TestHTTPCheckTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := &http.Client{Timeout: 100 * time.Millisecond}
	cr := httpCheck(context.Background(), client, server.URL)

	if cr.statusCode != nil {
		t.Errorf("expected nil status code on timeout, got %d", *cr.statusCode)
	}
	if cr.isUp {
		t.Error("expected isUp = false on timeout")
	}
}

// verifies redirects remain reachable without being followed.
func TestHTTPCheckRedirect(t *testing.T) {
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://example.com", http.StatusMovedPermanently)
	}))
	defer redirect.Close()

	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	cr := httpCheck(context.Background(), client, redirect.URL)

	if cr.statusCode == nil || *cr.statusCode != 301 {
		t.Errorf("expected status 301, got %d", *cr.statusCode)
	}
	if !cr.isUp {
		t.Error("expected isUp = true for 301 (redirects are reachable)")
	}
}

// verifies a reachable database produces a healthy response.
func TestHealthzHandlerOK(t *testing.T) {
	testDB := openTestDB(t)
	defer closeTestDB(t, testDB)

	req := httptest.NewRequestWithContext(context.Background(), "GET", "/healthz", nil)
	w := httptest.NewRecorder()
	HandleHealthz(testDB)(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("json decode: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("expected status ok, got %v", body)
	}
}

// verifies status responses contain persisted check data.
func TestStatusJSON(t *testing.T) {
	testDB := openTestDB(t)
	defer closeTestDB(t, testDB)

	db.RecordCheck(context.Background(), testDB, "https://example.com", intPtr(200), 100, true)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", HandleStatus(testDB))

	req := httptest.NewRequestWithContext(context.Background(), "GET", "/status", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	var resp []db.TargetStatus
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json decode: %v", err)
	}
	if len(resp) == 0 {
		t.Error("expected at least one status entry")
	}
}

// verifies history returns only exact target URL matches.
func TestHistoryJSON(t *testing.T) {
	testDB := openTestDB(t)
	defer closeTestDB(t, testDB)

	db.RecordCheck(context.Background(), testDB, "https://example.com", intPtr(200), 100, true)
	db.RecordCheck(context.Background(), testDB, "https://example.com", intPtr(500), 200, false)
	db.RecordCheck(context.Background(), testDB, "https://example.com/status", intPtr(200), 50, true)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /history", HandleHistory(testDB))

	req := httptest.NewRequestWithContext(context.Background(), "GET", "/history?target=https://example.com&limit=10", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	var resp []db.CheckRow
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json decode: %v", err)
	}
	if len(resp) != 2 {
		t.Errorf("expected 2 history entries, got %d", len(resp))
	}
	for _, check := range resp {
		if check.TargetURL != "https://example.com" {
			t.Errorf("history included non-exact target %q", check.TargetURL)
		}
	}
}

// creates nullable status-code test values.
func intPtr(i int) *int { return &i }

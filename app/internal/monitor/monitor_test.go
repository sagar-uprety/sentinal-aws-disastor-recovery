package monitor

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	_ "github.com/lib/pq"

	"sentinel-aws-dr/app/internal/db"
)

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	testDB, err := sql.Open("postgres", "postgres://postgres:postgres@localhost:5432/sentinel?sslmode=disable")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := testDB.Ping(); err != nil {
		t.Fatalf("db ping: %v (is Postgres running? try: docker compose up -d db)", err)
	}
	testDB.Exec("TRUNCATE targets, checks RESTART IDENTITY CASCADE")
	if err := db.Migrate(testDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := db.SeedTargets(testDB, ""); err != nil {
		t.Fatalf("seed targets: %v", err)
	}
	return testDB
}

func TestHTTPCheckUp(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}))
	defer server.Close()

	client := &http.Client{Timeout: 5 * time.Second}
	cr := httpCheck(client, server.URL)

	if cr.statusCode == nil || *cr.statusCode != 200 {
		t.Errorf("expected status 200, got %v", cr.statusCode)
	}
	if !cr.isUp {
		t.Error("expected isUp = true")
	}
}

func TestHTTPCheckDown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("error"))
	}))
	defer server.Close()

	client := &http.Client{Timeout: 5 * time.Second}
	cr := httpCheck(client, server.URL)

	if cr.statusCode == nil || *cr.statusCode != 500 {
		t.Errorf("expected status 500, got %v", cr.statusCode)
	}
	if cr.isUp {
		t.Error("expected isUp = false for 5xx")
	}
}

func TestHTTPCheckTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := &http.Client{Timeout: 100 * time.Millisecond}
	cr := httpCheck(client, server.URL)

	if cr.statusCode != nil {
		t.Errorf("expected nil status code on timeout, got %d", *cr.statusCode)
	}
	if cr.isUp {
		t.Error("expected isUp = false on timeout")
	}
}

func TestHTTPCheckRedirect(t *testing.T) {
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://example.com", http.StatusMovedPermanently)
	}))
	defer redirect.Close()

	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	cr := httpCheck(client, redirect.URL)

	if cr.statusCode == nil || *cr.statusCode != 301 {
		t.Errorf("expected status 301, got %d", *cr.statusCode)
	}
	if !cr.isUp {
		t.Error("expected isUp = true for 301 (redirects are reachable)")
	}
}

func TestHealthzHandlerOK(t *testing.T) {
	testDB := openTestDB(t)
	defer testDB.Close()

	req := httptest.NewRequest("GET", "/healthz", nil)
	w := httptest.NewRecorder()
	HandleHealthz(testDB)(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	var body map[string]string
	json.Unmarshal(w.Body.Bytes(), &body)
	if body["status"] != "ok" {
		t.Errorf("expected status ok, got %v", body)
	}
}

func TestStatusJSON(t *testing.T) {
	testDB := openTestDB(t)
	defer testDB.Close()

	db.RecordCheck(testDB, "https://example.com", intPtr(200), 100, true)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", HandleStatus(testDB))

	req := httptest.NewRequest("GET", "/status", nil)
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

func TestHistoryJSON(t *testing.T) {
	testDB := openTestDB(t)
	defer testDB.Close()

	db.RecordCheck(testDB, "https://example.com", intPtr(200), 100, true)
	db.RecordCheck(testDB, "https://example.com", intPtr(500), 200, false)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /history", HandleHistory(testDB))

	req := httptest.NewRequest("GET", "/history?target=https://example.com&limit=10", nil)
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
}

func intPtr(i int) *int { return &i }

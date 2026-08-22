package httpapi

import (
	"context"
	"crypto/subtle"
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"aws-pilotlight-multi-region-dr/apps/url-shortener/internal/links"
)

// single-file UI (inline CSS/JS, no build step) served at GET /; talks to the JSON API below via fetch.
//
//go:embed static/index.html
var indexHTML string

var slugPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{3,32}$`)

// narrow persistence dependency the server needs; implemented by links.Store, letting tests substitute a fake.
type store interface {
	Ping(context.Context) error
	Create(context.Context, string, string) (links.Link, error)
	Get(context.Context, string) (links.Link, error)
	List(context.Context, int) ([]links.Link, error)
}

type server struct {
	store store
	token string
}

// builds the full HTTP handler: health, link CRUD/redirect, and the static index page.
func New(store store, token string) http.Handler {
	s := &server{store: store, token: token}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /links", s.list)
	mux.HandleFunc("POST /links", s.create)
	// "/{$}" matches only the exact root path, so the "/{slug}" wildcard below never swallows it.
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /{slug}", s.redirect)
	return mux
}

// reports 503 when the database is unreachable; used by ECS/ALB health checks.
func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// creates a short link behind the operator token; rejects malformed slugs/URLs and duplicate slugs.
func (s *server) create(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r.Header.Get("Authorization")) {
		writeError(w, http.StatusUnauthorized, "valid operator token required")
		return
	}
	var input struct {
		DestinationURL string `json:"destination_url"`
		Slug           string `json:"slug"`
	}
	// caps the body at 4KB and rejects unknown fields, so a malformed or oversized payload fails before touching the database.
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	// a second Decode call that doesn't hit io.EOF means there was trailing content after the first JSON value.
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "body must contain one JSON object")
		return
	}
	if !slugPattern.MatchString(input.Slug) {
		writeError(w, http.StatusBadRequest, "slug must be 3-32 letters, numbers, underscores, or hyphens")
		return
	}
	if !validDestination(input.DestinationURL) {
		writeError(w, http.StatusBadRequest, "destination_url must be an HTTP or HTTPS URL")
		return
	}
	link, err := s.store.Create(r.Context(), input.Slug, input.DestinationURL)
	if errors.Is(err, links.ErrSlugExists) {
		writeError(w, http.StatusConflict, "slug already exists")
		return
	}
	if err != nil {
		slog.Error("create link failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusCreated, link)
}

// returns the 50 most recently created links.
func (s *server) list(w http.ResponseWriter, r *http.Request) {
	result, err := s.store.List(r.Context(), 50)
	if err != nil {
		slog.Error("list links failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// resolves a slug and 302s to its destination; 404s on an unknown slug.
func (s *server) redirect(w http.ResponseWriter, r *http.Request) {
	link, err := s.store.Get(r.Context(), r.PathValue("slug"))
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "short link not found")
		return
	}
	if err != nil {
		slog.Error("get link failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	http.Redirect(w, r, link.DestinationURL, http.StatusFound)
}

// serves the single-page UI.
func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if _, err := io.WriteString(w, indexHTML); err != nil {
		slog.Error("write index failed", "error", err)
	}
}

// checks the bearer token in constant time to avoid leaking its value through response-time differences.
func (s *server) authorized(header string) bool {
	provided, ok := strings.CutPrefix(header, "Bearer ")
	// length is compared first because ConstantTimeCompare returns 0 for unequal lengths without comparing content; only the length leaks, never the token.
	if !ok || len(provided) != len(s.token) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) == 1
}

// rejects anything but a canonical http/https URL with no embedded credentials.
func validDestination(raw string) bool {
	parsed, err := url.ParseRequestURI(raw)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" && parsed.User == nil
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

// writes value as a JSON response body with the given status code.
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("encode response failed", "error", err)
	}
}

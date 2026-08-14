package monitor

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"aws-pilotlight-multi-region-dr/apps/monitor/internal/store"
	"aws-pilotlight-multi-region-dr/apps/monitor/internal/topology"
)

// reports 503 when the store backend is unreachable; used by ECS/ALB health checks.
func HandleHealthz(dataStore store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := dataStore.Health(r.Context()); err != nil {
			slog.Error("healthz: store unavailable", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "error"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// lists every target the checker currently tracks.
func HandleTargets(dataStore store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		targets, err := dataStore.ListTargets(r.Context())
		if err != nil {
			slog.Error("targets: list failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if targets == nil {
			targets = []store.Target{}
		}
		writeJSON(w, http.StatusOK, targets)
	}
}

// returns each target's latest check plus its uptime over the trailing 24h.
func HandleStatus(dataStore store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		statuses, err := dataStore.LatestStatuses(r.Context(), time.Now().UTC().Add(-24*time.Hour))
		if err != nil {
			slog.Error("status: query failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if statuses == nil {
			statuses = []store.TargetStatus{}
		}
		writeJSON(w, http.StatusOK, statuses)
	}
}

// returns recent checks for one target, requiring ?target and capping ?limit to protect the store.
func HandleHistory(dataStore store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		if target == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "target query parameter required"})
			return
		}
		limit := 100
		// silently falls back to the 100 default on an invalid or out-of-range limit rather than erroring.
		if value, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && value > 0 && value <= 500 {
			limit = value
		}
		checks, err := dataStore.History(r.Context(), target, limit)
		if err != nil {
			slog.Error("history: query failed", "target", target, "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if checks == nil {
			checks = []store.Check{}
		}
		writeJSON(w, http.StatusOK, checks)
	}
}

// serves the current prod/DR ECS+RDS topology snapshot.
func HandleTopology(service *topology.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, service.Snapshot(r.Context()))
	}
}

// writes value as a JSON response body with the given status code.
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

package monitor

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"sentinel-aws-dr/app/internal/store"
	"sentinel-aws-dr/app/internal/topology"
)

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

func HandleHistory(dataStore store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		if target == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "target query parameter required"})
			return
		}
		limit := 100
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

func HandleTopology(service *topology.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, service.Snapshot(r.Context()))
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

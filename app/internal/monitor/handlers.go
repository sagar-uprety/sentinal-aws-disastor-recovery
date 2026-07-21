package monitor

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"sentinel-aws-dr/app/internal/db"
	"sentinel-aws-dr/app/internal/topology"
)

// reports readiness based on database connectivity.
func HandleHealthz(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := database.PingContext(r.Context()); err != nil {
			slog.Error("healthz: db ping failed", "error", err)
			http.Error(w, `{"status":"error"}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write([]byte(`{"status":"ok"}`)); err != nil {
			slog.Error("healthz: write response failed", "error", err)
		}
	}
}

// returns all configured monitoring targets.
func HandleTargets(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		targets, err := db.ListTargets(r.Context(), database)
		if err != nil {
			slog.Error("targets: list failed", "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		type targetResp struct {
			URL string `json:"url"`
			ID  int    `json:"id"`
		}
		resp := make([]targetResp, len(targets))
		for i, t := range targets {
			resp[i] = targetResp{ID: t.ID, URL: t.URL}
		}
		writeJSON(w, resp)
	}
}

// returns the latest status and 24-hour uptime for each target.
func HandleStatus(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		statuses, err := db.GetLatestPerTarget(r.Context(), database)
		if err != nil {
			slog.Error("status: query failed", "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if statuses == nil {
			statuses = []db.TargetStatus{}
		}
		writeJSON(w, statuses)
	}
}

// returns recent checks for the requested exact target URL.
func HandleHistory(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		if target == "" {
			http.Error(w, `{"error":"target query parameter required"}`, http.StatusBadRequest)
			return
		}
		limitStr := r.URL.Query().Get("limit")
		limit := 100
		if limitStr != "" {
			if v, err := strconv.Atoi(limitStr); err == nil && v > 0 && v <= 500 {
				limit = v
			}
		}
		checks, err := db.GetHistory(r.Context(), database, target, limit)
		if err != nil {
			slog.Error("history: query failed", "target", target, "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if checks == nil {
			checks = []db.CheckRow{}
		}
		writeJSON(w, checks)
	}
}

// returns runtime ECS and RDS topology for the status-page resilience view.
func HandleTopology(service *topology.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, service.Snapshot(r.Context()))
	}
}

// writes a JSON response with the requested status code.
func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

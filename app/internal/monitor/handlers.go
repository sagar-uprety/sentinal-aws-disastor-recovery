package monitor

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"sentinel-aws-dr/app/internal/db"
)

// HandleHealthz reports readiness based on database connectivity.
func HandleHealthz(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := database.Ping(); err != nil {
			slog.Error("healthz: db ping failed", "error", err)
			http.Error(w, `{"status":"error"}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	}
}

// HandleTargets returns all configured monitoring targets.
func HandleTargets(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		targets, err := db.ListTargets(database)
		if err != nil {
			slog.Error("targets: list failed", "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		type targetResp struct {
			ID  int    `json:"id"`
			URL string `json:"url"`
		}
		resp := make([]targetResp, len(targets))
		for i, t := range targets {
			resp[i] = targetResp{ID: t.ID, URL: t.URL}
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

// HandleStatus returns the latest status and 24-hour uptime for each target.
func HandleStatus(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		statuses, err := db.GetLatestPerTarget(database)
		if err != nil {
			slog.Error("status: query failed", "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if statuses == nil {
			statuses = []db.TargetStatus{}
		}
		writeJSON(w, http.StatusOK, statuses)
	}
}

// HandleHistory returns recent checks for the requested exact target URL.
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
		checks, err := db.GetHistory(database, target, limit)
		if err != nil {
			slog.Error("history: query failed", "target", target, "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if checks == nil {
			checks = []db.CheckRow{}
		}
		writeJSON(w, http.StatusOK, checks)
	}
}

// writeJSON writes a JSON response with the requested status code.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

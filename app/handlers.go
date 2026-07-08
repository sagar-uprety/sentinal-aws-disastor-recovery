package main

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
)

func handleHealthz(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			slog.Error("healthz: db ping failed", "error", err)
			http.Error(w, `{"status":"error"}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	}
}

func handleTargets(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		targets, err := listTargets(db)
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

func handleStatus(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		statuses, err := getLatestPerTarget(db)
		if err != nil {
			slog.Error("status: query failed", "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if statuses == nil {
			statuses = []targetStatus{}
		}
		writeJSON(w, http.StatusOK, statuses)
	}
}

func handleHistory(db *sql.DB) http.HandlerFunc {
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
		checks, err := getHistory(db, target, limit)
		if err != nil {
			slog.Error("history: query failed", "target", target, "error", err)
			http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
			return
		}
		if checks == nil {
			checks = []checkRow{}
		}
		writeJSON(w, http.StatusOK, checks)
	}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type config struct {
	port                 int
	databaseURL          string
	selfURL              string
	checkInterval        time.Duration
	httpTimeout          time.Duration
}

func loadConfig() config {
	port, _ := strconv.Atoi(envOrDefault("PORT", "8080"))
	interval, _ := strconv.Atoi(envOrDefault("CHECK_INTERVAL_SECONDS", "30"))
	return config{
		port:          port,
		databaseURL:   envOrDefault("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/sentinel?sslmode=disable"),
		selfURL:       os.Getenv("SELF_URL"),
		checkInterval: time.Duration(interval) * time.Second,
		httpTimeout:   5 * time.Second,
	}
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	cfg := loadConfig()

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
	slog.Info("starting sentinel", "port", cfg.port, "interval", cfg.checkInterval.Seconds())

	db, err := openDB(cfg.databaseURL)
	if err != nil {
		slog.Error("failed to connect to database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := migrate(db); err != nil {
		slog.Error("failed to run migrations", "error", err)
		os.Exit(1)
	}

	if err := seedTargets(db, cfg.selfURL); err != nil {
		slog.Error("failed to seed targets", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	metrics := newMetrics()
	checker := newChecker(db, metrics, cfg.checkInterval, cfg.httpTimeout, cfg.selfURL)
	go checker.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz(db))
	mux.HandleFunc("GET /targets", handleTargets(db))
	mux.HandleFunc("GET /status", handleStatus(db))
	mux.HandleFunc("GET /history", handleHistory(db))
	mux.HandleFunc("GET /metrics", promhttp.HandlerFor(metrics.registry, promhttp.HandlerOpts{}).ServeHTTP)
	mux.Handle("GET /", http.FileServer(http.Dir("static")))

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.port),
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		slog.Info("shutting down")
		ctxShutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		server.Shutdown(ctxShutdown)
		cancel()
	}()

	slog.Info("listening", "addr", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}
}

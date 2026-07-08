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

	"sentinel-aws-dr/app/internal/db"
	"sentinel-aws-dr/app/internal/monitor"
)

type config struct {
	port          int
	databaseURL   string
	selfURL       string
	checkInterval time.Duration
	httpTimeout   time.Duration
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

	database, err := db.Open(cfg.databaseURL)
	if err != nil {
		slog.Error("failed to connect to database", "error", err)
		os.Exit(1)
	}
	defer database.Close()

	if err := db.Migrate(database); err != nil {
		slog.Error("failed to run migrations", "error", err)
		os.Exit(1)
	}
	if err := db.SeedTargets(database, cfg.selfURL); err != nil {
		slog.Error("failed to seed targets", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	metrics := monitor.NewMetrics()
	checker := monitor.NewChecker(database, metrics, cfg.checkInterval, cfg.httpTimeout, cfg.selfURL)
	go checker.Run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", monitor.HandleHealthz(database))
	mux.HandleFunc("GET /targets", monitor.HandleTargets(database))
	mux.HandleFunc("GET /status", monitor.HandleStatus(database))
	mux.HandleFunc("GET /history", monitor.HandleHistory(database))
	mux.HandleFunc("GET /metrics", promhttp.HandlerFor(metrics.Registry, promhttp.HandlerOpts{}).ServeHTTP)
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

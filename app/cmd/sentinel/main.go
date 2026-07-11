package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
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

// Validates environment settings and returns runtime configuration.
func loadConfig() (config, error) {
	port, err := strconv.Atoi(envOrDefault("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return config{}, fmt.Errorf("PORT must be an integer between 1 and 65535")
	}
	interval, err := strconv.Atoi(envOrDefault("CHECK_INTERVAL_SECONDS", "30"))
	if err != nil || interval < 1 {
		return config{}, fmt.Errorf("CHECK_INTERVAL_SECONDS must be a positive integer")
	}
	databaseURL, err := databaseConnectionURL()
	if err != nil {
		return config{}, err
	}
	return config{
		port:          port,
		databaseURL:   databaseURL,
		selfURL:       os.Getenv("SELF_URL"),
		checkInterval: time.Duration(interval) * time.Second,
		httpTimeout:   5 * time.Second,
	}, nil
}

// Resolves exactly one supported database configuration path.
func databaseConnectionURL() (string, error) {
	// ECS supplies split DB values, while local development may use one DATABASE_URL.
	databaseURL := os.Getenv("DATABASE_URL")
	dbValues := map[string]string{
		"DB_HOST":     os.Getenv("DB_HOST"),
		"DB_PORT":     os.Getenv("DB_PORT"),
		"DB_NAME":     os.Getenv("DB_NAME"),
		"DB_USER":     os.Getenv("DB_USER"),
		"DB_PASSWORD": os.Getenv("DB_PASSWORD"),
	}
	hasDBValues := false
	var missing []string
	for name, value := range dbValues {
		if value != "" {
			hasDBValues = true
		} else {
			missing = append(missing, name)
		}
	}
	if databaseURL != "" && hasDBValues {
		return "", fmt.Errorf("DATABASE_URL and DB_* variables are mutually exclusive")
	}
	if databaseURL != "" {
		return databaseURL, nil
	}
	if len(missing) > 0 {
		return "", fmt.Errorf("database configuration missing: %s", strings.Join(missing, ", "))
	}

	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(dbValues["DB_USER"], dbValues["DB_PASSWORD"]),
		Host:   net.JoinHostPort(dbValues["DB_HOST"], dbValues["DB_PORT"]),
		Path:   dbValues["DB_NAME"],
	}
	u.RawQuery = "sslmode=disable"
	return u.String(), nil
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Starts the checker, metrics endpoint, and HTTP server.
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
	cfg, err := loadConfig()
	if err != nil {
		slog.Error("invalid configuration", "error", err)
		os.Exit(1)
	}
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
		// Stop checks first, then give active HTTP requests time to finish.
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

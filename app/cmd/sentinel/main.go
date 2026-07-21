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

	"sentinel-aws-dr/app/internal/db"
	"sentinel-aws-dr/app/internal/monitor"
	"sentinel-aws-dr/app/internal/topology"
)

type config struct {
	databaseURL   string
	region        string
	databaseID    string
	port          int
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
		region:        envOrDefault("AWS_REGION", "local"),
		databaseID:    os.Getenv("DB_INSTANCE_IDENTIFIER"),
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
	u.RawQuery = "sslmode=require"
	return u.String(), nil
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

// Starts the checker and HTTP server.
func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	slog.Info("starting sentinel", "port", cfg.port, "interval", cfg.checkInterval.Seconds())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	database, err := db.Open(ctx, cfg.databaseURL)
	if err != nil {
		return fmt.Errorf("failed to connect to database: %w", err)
	}
	defer func() {
		if cerr := database.Close(); cerr != nil {
			slog.Error("close database failed", "error", cerr)
		}
	}()

	if err = db.Migrate(ctx, database); err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}
	targets, err := db.LoadTargets("targets.json")
	if err != nil {
		return fmt.Errorf("load targets: %w", err)
	}
	if err = db.SeedTargets(ctx, database, targets); err != nil {
		return fmt.Errorf("failed to seed targets: %w", err)
	}

	checker := monitor.NewChecker(database, cfg.checkInterval, cfg.httpTimeout)
	go checker.Run(ctx)
	topologyService := topology.New(ctx, cfg.region, cfg.databaseID)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", monitor.HandleHealthz(database))
	mux.HandleFunc("GET /targets", monitor.HandleTargets(database))
	mux.HandleFunc("GET /status", monitor.HandleStatus(database))
	mux.HandleFunc("GET /history", monitor.HandleHistory(database))
	mux.HandleFunc("GET /topology", monitor.HandleTopology(topologyService))
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
		ctxShutdown, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancelShutdown()
		if shutdownErr := server.Shutdown(ctxShutdown); shutdownErr != nil {
			slog.Error("http server shutdown failed", "error", shutdownErr)
		}
		cancel()
	}()

	slog.Info("listening", "addr", server.Addr)
	if err = server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("server error: %w", err)
	}
	return nil
}

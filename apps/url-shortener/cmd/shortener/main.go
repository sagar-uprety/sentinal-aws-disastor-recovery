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

	"aws-pilotlight-multi-region-dr/apps/url-shortener/internal/httpapi"
	"aws-pilotlight-multi-region-dr/apps/url-shortener/internal/links"
)

type config struct {
	databaseURL string
	createToken string
	port        int
}

// reads and validates all runtime configuration from environment variables.
func loadConfig() (config, error) {
	port, err := strconv.Atoi(envOrDefault("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return config{}, fmt.Errorf("PORT must be an integer between 1 and 65535")
	}
	databaseURL, err := databaseConnectionURL()
	if err != nil {
		return config{}, err
	}
	token := os.Getenv("LINK_CREATE_TOKEN")
	if len(token) < 16 {
		return config{}, fmt.Errorf("LINK_CREATE_TOKEN must contain at least 16 characters")
	}
	return config{databaseURL: databaseURL, createToken: token, port: port}, nil
}

// accepts either a single DATABASE_URL (local-dev convenience) or the five individual DB_* vars ECS injects in prod/DR, never both.
func databaseConnectionURL() (string, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	dbValues := map[string]string{
		"DB_HOST":     os.Getenv("DB_HOST"),
		"DB_PORT":     os.Getenv("DB_PORT"),
		"DB_NAME":     os.Getenv("DB_NAME"),
		"DB_USER":     os.Getenv("DB_USER"),
		"DB_PASSWORD": os.Getenv("DB_PASSWORD"),
	}
	hasDBValues := false
	missing := make([]string, 0)
	for name, value := range dbValues {
		if value == "" {
			missing = append(missing, name)
		} else {
			hasDBValues = true
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
	parsed := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(dbValues["DB_USER"], dbValues["DB_PASSWORD"]),
		Host:   net.JoinHostPort(dbValues["DB_HOST"], dbValues["DB_PORT"]),
		Path:   dbValues["DB_NAME"],
	}
	// RDS requires TLS; url.URL has no dedicated query field, so this is set after construction.
	parsed.RawQuery = "sslmode=require"
	return parsed.String(), nil
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// sets up structured JSON logging, then delegates to run and exits non-zero on failure.
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

// opens the database, runs migrations, then serves HTTP until a shutdown signal is received.
func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	ctx := context.Background()
	store, err := links.Open(ctx, cfg.databaseURL)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := store.Close(); closeErr != nil {
			slog.Error("close database failed", "error", closeErr)
		}
	}()
	if err := store.Migrate(ctx); err != nil {
		return err
	}

	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.port),
		Handler:           httpapi.New(store, cfg.createToken),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	// gives an in-flight request up to 10s to finish before the process exits on SIGINT/SIGTERM.
	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-shutdown
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			slog.Error("shutdown failed", "error", err)
		}
	}()

	slog.Info("URL shortener listening", "address", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}

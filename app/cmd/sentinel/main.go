package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"sentinel-aws-dr/app/internal/monitor"
	"sentinel-aws-dr/app/internal/store"
	"sentinel-aws-dr/app/internal/topology"
)

type config struct {
	monitoredURL  string
	dynamoTable   string
	awsRegion     string
	regions       []topology.RegionConfig
	port          int
	checkInterval time.Duration
	httpTimeout   time.Duration
}

func loadConfig() (config, error) {
	port, err := positiveInt("PORT", 8080)
	if err != nil || port > 65535 {
		return config{}, fmt.Errorf("PORT must be an integer between 1 and 65535")
	}
	interval, err := positiveInt("CHECK_INTERVAL_SECONDS", 30)
	if err != nil {
		return config{}, fmt.Errorf("CHECK_INTERVAL_SECONDS must be a positive integer")
	}
	target := envOrDefault("MONITORED_URL", "http://localhost:8081/healthz")
	if targetErr := validateTarget(target); targetErr != nil {
		return config{}, targetErr
	}
	table, awsRegion := os.Getenv("DYNAMODB_TABLE"), os.Getenv("AWS_REGION")
	if table != "" && awsRegion == "" {
		return config{}, fmt.Errorf("AWS_REGION is required when DYNAMODB_TABLE is set")
	}
	regions, err := topologyConfig()
	if err != nil {
		return config{}, err
	}
	return config{
		monitoredURL: target, dynamoTable: table, awsRegion: awsRegion, port: port,
		checkInterval: time.Duration(interval) * time.Second, httpTimeout: 5 * time.Second,
		regions: regions,
	}, nil
}

func topologyConfig() ([]topology.RegionConfig, error) {
	prefixes := []string{"PROD", "DR"}
	regions := make([]topology.RegionConfig, 0, len(prefixes))
	for _, prefix := range prefixes {
		values := map[string]string{
			"AWS_REGION":    os.Getenv(prefix + "_AWS_REGION"),
			"ECS_CLUSTER":   os.Getenv(prefix + "_ECS_CLUSTER"),
			"ECS_SERVICE":   os.Getenv(prefix + "_ECS_SERVICE"),
			"DB_IDENTIFIER": os.Getenv(prefix + "_DB_IDENTIFIER"),
		}
		configured := 0
		for _, value := range values {
			if value != "" {
				configured++
			}
		}
		if configured == 0 {
			continue
		}
		if configured != len(values) {
			return nil, fmt.Errorf("%s topology requires %s_AWS_REGION, %s_ECS_CLUSTER, %s_ECS_SERVICE, and %s_DB_IDENTIFIER", prefix, prefix, prefix, prefix, prefix)
		}
		regions = append(regions, topology.RegionConfig{
			Region: values["AWS_REGION"], ECSCluster: values["ECS_CLUSTER"],
			ECSService: values["ECS_SERVICE"], DatabaseIdentifier: values["DB_IDENTIFIER"],
		})
	}
	return regions, nil
}

func positiveInt(name string, fallback int) (int, error) {
	value, err := strconv.Atoi(envOrDefault(name, strconv.Itoa(fallback)))
	if err != nil || value < 1 {
		return 0, fmt.Errorf("%s must be positive", name)
	}
	return value, nil
}

func validateTarget(raw string) error {
	parsed, err := url.ParseRequestURI(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return fmt.Errorf("MONITORED_URL must be a canonical HTTP or HTTPS URL")
	}
	return nil
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var dataStore store.Store = store.NewMemory(cfg.monitoredURL)
	storeKind := "memory"
	if cfg.dynamoTable != "" {
		awsCfg, loadErr := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.awsRegion))
		if loadErr != nil {
			return fmt.Errorf("load AWS configuration: %w", loadErr)
		}
		dataStore = store.NewDynamoDB(dynamodb.NewFromConfig(awsCfg), cfg.dynamoTable, cfg.monitoredURL)
		storeKind = "dynamodb"
	}
	slog.Info("starting sentinel", "port", cfg.port, "target", cfg.monitoredURL, "store", storeKind, "interval_seconds", cfg.checkInterval.Seconds())

	checker := monitor.NewChecker(dataStore, cfg.monitoredURL, cfg.checkInterval, cfg.httpTimeout)
	go checker.Run(ctx)
	topologyService := topology.New(ctx, cfg.regions)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", monitor.HandleHealthz(dataStore))
	mux.HandleFunc("GET /targets", monitor.HandleTargets(dataStore))
	mux.HandleFunc("GET /status", monitor.HandleStatus(dataStore))
	mux.HandleFunc("GET /history", monitor.HandleHistory(dataStore))
	mux.HandleFunc("GET /events", monitor.HandleEvents(dataStore))
	mux.HandleFunc("GET /topology", monitor.HandleTopology(topologyService))
	mux.Handle("GET /", http.FileServer(http.Dir("static")))
	server := &http.Server{
		Addr: fmt.Sprintf(":%d", cfg.port), Handler: mux,
		ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second,
	}
	go shutdownOnSignal(server, cancel)
	slog.Info("listening", "addr", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("server error: %w", err)
	}
	return nil
}

func shutdownOnSignal(server *http.Server, cancel context.CancelFunc) {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	<-signals
	slog.Info("shutting down")
	cancel()
	ctx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(ctx); err != nil {
		slog.Error("http server shutdown failed", "error", err)
	}
}

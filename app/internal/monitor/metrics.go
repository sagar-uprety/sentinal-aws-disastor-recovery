package monitor

import (
	"context"
	"os"
	"sync"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	otelmetric "go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.30.0"
)

type Metrics struct {
	checksCounter otelmetric.Int64Counter
	durationHist  otelmetric.Int64Histogram

	mu          sync.RWMutex
	targetState map[string]int64

	provider *sdkmetric.MeterProvider
}

// creates an OTLP push pipeline and returns its shutdown function.
func NewMetrics(ctx context.Context) (*Metrics, func(context.Context) error, error) {
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("sentinel"),
			semconv.ServiceVersion("0.1.0"),
		),
	)
	if err != nil {
		return nil, nil, err
	}

	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "http://localhost:4318"
	}

	exporter, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpointURL(endpoint),
	)
	if err != nil {
		return nil, nil, err
	}

	reader := sdkmetric.NewPeriodicReader(exporter)
	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(reader),
	)
	otel.SetMeterProvider(provider)

	meter := provider.Meter("sentinel",
		otelmetric.WithInstrumentationVersion("0.1.0"),
	)

	checksCounter, err := meter.Int64Counter("sentinel.checks",
		otelmetric.WithDescription("Total checks performed"),
	)
	if err != nil {
		return nil, nil, err
	}

	durationHist, err := meter.Int64Histogram("sentinel.check.duration",
		otelmetric.WithDescription("HTTP check duration in milliseconds"),
		otelmetric.WithUnit("ms"),
		otelmetric.WithExplicitBucketBoundaries(10, 50, 100, 250, 500, 1000, 2000, 5000),
	)
	if err != nil {
		return nil, nil, err
	}

	m := &Metrics{
		checksCounter: checksCounter,
		durationHist:  durationHist,
		targetState:   make(map[string]int64),
		provider:      provider,
	}

	_, err = meter.Int64ObservableGauge("sentinel.target.up",
		otelmetric.WithInt64Callback(m.observeUpGauge),
		otelmetric.WithDescription("Target reachable (1) or not (0)"),
	)
	if err != nil {
		return nil, nil, err
	}

	return m, provider.Shutdown, nil
}

// exports the latest bounded up/down state for each target.
func (m *Metrics) observeUpGauge(_ context.Context, obs otelmetric.Int64Observer) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for target, state := range m.targetState {
		obs.Observe(state, otelmetric.WithAttributeSet(
			attribute.NewSet(attribute.String("target", target)),
		))
	}
	return nil
}

// records check count, duration, and latest target state.
func (m *Metrics) Observe(ctx context.Context, target string, responseMs int, isUp bool) {
	// Target labels are bounded by the small configured target table.
	attrs := otelmetric.WithAttributeSet(
		attribute.NewSet(attribute.String("target", target)),
	)
	m.checksCounter.Add(ctx, 1, attrs)
	m.durationHist.Record(ctx, int64(responseMs), attrs)
	m.mu.Lock()
	if isUp {
		m.targetState[target] = 1
	} else {
		m.targetState[target] = 0
	}
	m.mu.Unlock()
}

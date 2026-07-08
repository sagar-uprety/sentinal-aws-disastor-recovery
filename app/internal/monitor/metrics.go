package monitor

import (
	"context"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"go.opentelemetry.io/otel/attribute"
	otelprom "go.opentelemetry.io/otel/exporters/prometheus"
	otelmetric "go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/sdk/metric"
)

type Metrics struct {
	Registry      *prometheus.Registry
	checksCounter otelmetric.Int64Counter
	durationHist  otelmetric.Int64Histogram

	mu          sync.RWMutex
	targetState map[string]int64
}

func NewMetrics() *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	exporter, err := otelprom.New(otelprom.WithRegisterer(reg))
	if err != nil {
		panic("failed to create prometheus exporter: " + err.Error())
	}

	meterProvider := metric.NewMeterProvider(metric.WithReader(exporter))
	meter := meterProvider.Meter("sentinel",
		otelmetric.WithInstrumentationVersion("0.1.0"),
	)

	checksCounter, err := meter.Int64Counter("sentinel.checks",
		otelmetric.WithDescription("Total checks performed"),
	)
	if err != nil {
		panic("failed to create counter: " + err.Error())
	}

	durationHist, err := meter.Int64Histogram("sentinel.check.duration",
		otelmetric.WithDescription("HTTP check duration in milliseconds"),
		otelmetric.WithUnit("ms"),
		otelmetric.WithExplicitBucketBoundaries(10, 50, 100, 250, 500, 1000, 2000, 5000),
	)
	if err != nil {
		panic("failed to create histogram: " + err.Error())
	}

	m := &Metrics{
		Registry:      reg,
		checksCounter: checksCounter,
		durationHist:  durationHist,
		targetState:   make(map[string]int64),
	}

	_, err = meter.Int64ObservableGauge("sentinel.target.up",
		otelmetric.WithInt64Callback(m.observeUpGauge),
		otelmetric.WithDescription("Target reachable (1) or not (0)"),
	)
	if err != nil {
		panic("failed to create gauge: " + err.Error())
	}

	return m
}

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

func (m *Metrics) Observe(ctx context.Context, target string, responseMs int, isUp bool) {
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

package store

import (
	"context"
	"math"
	"sync"
	"time"
)

// in-process Store for local dev; process-lifetime only, no persistence or eviction.
type Memory struct {
	target Target
	checks []Check
	mu     sync.RWMutex
}

// starts empty, tracking a single fixed target URL.
func NewMemory(targetURL string) *Memory {
	return &Memory{target: Target{URL: targetURL}}
}

func (m *Memory) ListTargets(context.Context) ([]Target, error) {
	return []Target{m.target}, nil
}

func (m *Memory) RecordCheck(_ context.Context, check Check) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.checks = append(m.checks, check)
	return nil
}

// walks checks newest-first and stops at the first one older than since, since checks is append-only and time-ordered.
func (m *Memory) LatestStatuses(_ context.Context, since time.Time) ([]TargetStatus, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if len(m.checks) == 0 {
		return []TargetStatus{}, nil
	}

	latest := m.checks[len(m.checks)-1]
	up, total := 0, 0
	for i := len(m.checks) - 1; i >= 0; i-- {
		if m.checks[i].CheckedAt.Before(since) {
			break
		}
		total++
		if m.checks[i].IsUp {
			up++
		}
	}
	return []TargetStatus{statusFromChecks(latest, up, total)}, nil
}

// scans newest-first for the target's most recent `limit` checks; already in descending CheckedAt order, no further sort needed.
func (m *Memory) History(_ context.Context, target string, limit int) ([]Check, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]Check, 0, limit)
	for i := len(m.checks) - 1; i >= 0 && len(result) < limit; i-- {
		if m.checks[i].TargetURL == target {
			result = append(result, m.checks[i])
		}
	}
	return result, nil
}

func (m *Memory) Health(context.Context) error { return nil }

// builds a TargetStatus from the newest check plus an up/total sample count, rounding uptime to one decimal place.
func statusFromChecks(latest Check, up, total int) TargetStatus {
	uptime := 0.0
	if total > 0 {
		// x1000 then /10 rounds to one decimal without a float formatting call.
		uptime = math.Round((1000*float64(up))/float64(total)) / 10
	}
	return TargetStatus{
		LastChecked:    latest.CheckedAt,
		StatusCode:     latest.StatusCode,
		URL:            latest.TargetURL,
		ResponseMs:     latest.ResponseMs,
		UptimePct:      uptime,
		SampleCount24h: total,
		IsUp:           latest.IsUp,
	}
}

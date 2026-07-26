package store

import (
	"context"
	"math"
	"sort"
	"sync"
	"time"
)

type Memory struct {
	target Target
	checks []Check
	events []DrillEvent
	mu     sync.RWMutex
}

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

func (m *Memory) History(_ context.Context, target string, limit int) ([]Check, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]Check, 0, limit)
	for i := len(m.checks) - 1; i >= 0 && len(result) < limit; i-- {
		if m.checks[i].TargetURL == target {
			result = append(result, m.checks[i])
		}
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].CheckedAt.After(result[j].CheckedAt) })
	return result, nil
}

func (m *Memory) AddEvent(event DrillEvent) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, event)
}

func (m *Memory) ListEvents(_ context.Context, limit int) ([]DrillEvent, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	events := append([]DrillEvent(nil), m.events...)
	sort.SliceStable(events, func(i, j int) bool { return events[i].Timestamp.After(events[j].Timestamp) })
	if len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}

func (m *Memory) Health(context.Context) error { return nil }

func statusFromChecks(latest Check, up, total int) TargetStatus {
	uptime := 0.0
	if total > 0 {
		uptime = math.Round((1000*float64(up))/float64(total)) / 10
	}
	return TargetStatus{
		LastChecked: latest.CheckedAt,
		StatusCode:  latest.StatusCode,
		URL:         latest.TargetURL,
		ResponseMs:  latest.ResponseMs,
		UptimePct:   uptime,
		IsUp:        latest.IsUp,
	}
}

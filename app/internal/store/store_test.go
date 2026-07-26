package store

import (
	"context"
	"testing"
	"time"
)

func TestMemoryStoreLifecycle(t *testing.T) {
	ctx := context.Background()
	memory := NewMemory("https://example.com/healthz")
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	for _, check := range []Check{
		{TargetURL: "https://example.com/healthz", CheckedAt: now.Add(-25 * time.Hour), IsUp: false},
		{TargetURL: "https://example.com/healthz", CheckedAt: now.Add(-time.Hour), IsUp: true, ResponseMs: 10},
		{TargetURL: "https://example.com/healthz", CheckedAt: now, IsUp: false, ResponseMs: 20},
	} {
		if err := memory.RecordCheck(ctx, check); err != nil {
			t.Fatalf("record check: %v", err)
		}
	}
	targets, _ := memory.ListTargets(ctx)
	statuses, _ := memory.LatestStatuses(ctx, now.Add(-24*time.Hour))
	history, _ := memory.History(ctx, targets[0].URL, 2)
	if len(targets) != 1 || len(statuses) != 1 || statuses[0].UptimePct != 50 || statuses[0].IsUp || len(history) != 2 {
		t.Fatalf("targets=%#v statuses=%#v history=%#v", targets, statuses, history)
	}
}

func TestMemoryStoreListsRecentEvents(t *testing.T) {
	memory := NewMemory("https://example.com/healthz")
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	memory.AddEvent(DrillEvent{Name: "older", Timestamp: now.Add(-time.Minute)})
	memory.AddEvent(DrillEvent{Name: "newer", Timestamp: now})
	events, err := memory.ListEvents(context.Background(), 1)
	if err != nil {
		t.Fatalf("list events: %v", err)
	}
	if len(events) != 1 || events[0].Name != "newer" {
		t.Fatalf("events = %#v", events)
	}
}

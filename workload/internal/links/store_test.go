package links

import (
	"context"
	"errors"
	"os"
	"testing"
)

func TestStoreLifecycle(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	store, openErr := Open(ctx, dsn)
	if openErr != nil {
		t.Fatalf("open store: %v", openErr)
	}
	t.Cleanup(func() {
		if _, err := store.db.ExecContext(ctx, `DROP TABLE IF EXISTS links`); err != nil {
			t.Errorf("drop links table: %v", err)
		}
		if err := store.Close(); err != nil {
			t.Errorf("close store: %v", err)
		}
	})
	if migrateErr := store.Migrate(ctx); migrateErr != nil {
		t.Fatalf("migrate: %v", migrateErr)
	}

	created, err := store.Create(ctx, "before-drill", "https://example.com/before")
	if err != nil {
		t.Fatalf("create link: %v", err)
	}
	loaded, err := store.Get(ctx, created.Slug)
	if err != nil {
		t.Fatalf("get link: %v", err)
	}
	if loaded.DestinationURL != created.DestinationURL {
		t.Fatalf("destination = %q, want %q", loaded.DestinationURL, created.DestinationURL)
	}
	if _, err := store.Create(ctx, created.Slug, "https://example.com/duplicate"); !errors.Is(err, ErrSlugExists) {
		t.Fatalf("duplicate error = %v, want ErrSlugExists", err)
	}
}

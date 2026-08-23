package links

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	// used for *pq.Error inspection in Create, and registers the "postgres" sql driver.
	"github.com/lib/pq"
)

var ErrSlugExists = errors.New("slug already exists")

type Link struct {
	CreatedAt      time.Time `json:"created_at"`
	DestinationURL string    `json:"destination_url"`
	Slug           string    `json:"slug"`
	ID             int64     `json:"id"`
}

type Store struct {
	db *sql.DB
}

// bounds the pool under RDS's small connection limit and pings first, so bad
// credentials or connectivity fail at startup instead of on the first request.
func Open(ctx context.Context, dsn string) (*Store, error) {
	database, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	database.SetMaxOpenConns(10)
	database.SetMaxIdleConns(5)
	database.SetConnMaxLifetime(5 * time.Minute)
	if err := database.PingContext(ctx); err != nil {
		if closeErr := database.Close(); closeErr != nil {
			return nil, fmt.Errorf("ping database: %w; close database: %v", err, closeErr)
		}
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return &Store{db: database}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

// safe on every startup, including against a freshly promoted replica.
func (s *Store) Migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS links (
			id BIGSERIAL primary KEY,
			slug TEXT UNIQUE NOT NULL,
			destination_url TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	if err != nil {
		return fmt.Errorf("migrate links: %w", err)
	}
	return nil
}

// inserts a link, translating a Postgres unique-violation (slug collision) into ErrSlugExists.
func (s *Store) Create(ctx context.Context, slug, destinationURL string) (Link, error) {
	var link Link
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO links (slug, destination_url)
		VALUES ($1, $2)
		RETURNING id, slug, destination_url, created_at`, slug, destinationURL).
		Scan(&link.ID, &link.Slug, &link.DestinationURL, &link.CreatedAt)
	if err != nil {
		var pqErr *pq.Error
		if errors.As(err, &pqErr) && pqErr.Code == "23505" {
			return Link{}, ErrSlugExists
		}
		return Link{}, fmt.Errorf("create link: %w", err)
	}
	return link, nil
}

// returns a wrapped sql.ErrNoRows for an unknown slug, which the HTTP layer maps to 404.
func (s *Store) Get(ctx context.Context, slug string) (Link, error) {
	var link Link
	err := s.db.QueryRowContext(ctx, `
		SELECT id, slug, destination_url, created_at
		FROM links
		WHERE slug = $1`, slug).
		Scan(&link.ID, &link.Slug, &link.DestinationURL, &link.CreatedAt)
	if err != nil {
		return Link{}, fmt.Errorf("get link: %w", err)
	}
	return link, nil
}

// returns the most recently created links, newest first, up to limit.
func (s *Store) List(ctx context.Context, limit int) ([]Link, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, slug, destination_url, created_at
		FROM links
		ORDER BY id DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("list links: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	links := make([]Link, 0)
	for rows.Next() {
		var link Link
		if err := rows.Scan(&link.ID, &link.Slug, &link.DestinationURL, &link.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan link: %w", err)
		}
		links = append(links, link)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate links: %w", err)
	}
	return links, nil
}

# Milestone 1 Evidence

Verified on 2026-07-11.

## Tests

- `go test ./...`: 11 tests passed across three packages with PostgreSQL running through Docker Compose.
- `go test -race ./...`: 11 tests passed across three packages.
- Configuration unit tests cover `DATABASE_URL`, complete `DB_*` variables, mixed configuration rejection, and incomplete configuration rejection.
- History integration test proves exact target URL matching by excluding a second URL with the same host and a different path.

## Runtime Verification

The app image was rebuilt before both runs.

- `DATABASE_URL` path: `/healthz`, `/status`, and `/` returned successful responses.
- Individual variable path: `DATABASE_URL` was unset and `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD` were set; `/healthz`, `/status`, and `/` returned successful responses.
- Application logs for the individual-variable run contained no errors or warnings.

## Container

- Multi-stage Go build with a scratch runtime image.
- Runtime user: `65534:65534`.
- Measured image size: 4,820,500 bytes (4.82 MB decimal), below the 30 MB target.

## Scope Reconciliation

Production Go code measures 664 physical lines across `main.go`, database access, checker, handlers, and metrics. The earlier approximate 400-line checkbox was already inaccurate before the final configuration work. Milestone wording now measures the intended constraint directly: the app remains one container with PostgreSQL persistence, no authentication, no user accounts, no alert engine, and no frontend build system.

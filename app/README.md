# Sentinel App

HTTP uptime checker and status page. Checks targets on a 30s interval, stores results in PostgreSQL, exposes a status API and a clean browser-based status page. Built with Go, distroless Docker image (15 MB), Prometheus metrics at /metrics.

## Quick start

```bash
docker compose up
```

Open http://localhost:8080.

## Endpoints

| Path | Description |
|------|-------------|
| GET /healthz | DB health check, returns {"status":"ok"} |
| GET /targets | List of monitored targets |
| GET /status | Latest check result per target with 24h uptime % |
| GET /history/{host} | Last 100 checks for a host |
| GET /metrics | Prometheus metrics (check_total, check_duration_ms, target_up) |
| GET / | Status page UI |

## Configuration

All via env vars: DATABASE_URL, SELF_URL, CHECK_INTERVAL_SECONDS (default 30), PORT (default 8080).

## Design intent

Single-purpose app: monitor external URLs, expose the data via JSON and a static HTML UI. The app stays trivial by design so the surrounding infrastructure (multi-AZ, DR, CI/CD) is the interesting part.

## Deliberate omissions

`checks.target_url` has no foreign key to `targets`. At this scale, orphan rows are harmless, and denormalizing the URL keeps history readable even if a target is removed.

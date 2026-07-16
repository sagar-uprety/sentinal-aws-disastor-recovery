# Sentinel App

HTTP uptime checker and status page. Checks targets on a 30s interval, stores results in PostgreSQL, exposes a status API and a clean browser-based status page. Built with Go, scratch-based Docker image (4.82 MB). Pushes OpenTelemetry metrics via OTLP to a collector.

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
| GET /history?target={URL} | Last 100 checks for an exact target URL |
| GET / | Status page UI |

## Configuration

Set database configuration using exactly one of these paths:

- Local convenience: `DATABASE_URL`
- ECS-style configuration: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`

Other variables: `SELF_URL`, `CHECK_INTERVAL_SECONDS` (default 30), `PORT` (default 8080), and `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`).

## Monitoring

Grafana at http://localhost:3000 (admin/admin).

## Design intent

Single-purpose app: monitor external URLs, expose the data via JSON and a static HTML UI. The app stays trivial by design so the surrounding infrastructure (multi-AZ, DR, CI/CD) is the interesting part.

## Deliberate omissions

`checks.target_url` has no foreign key to `targets`. At this scale, orphan rows are harmless, and denormalizing the URL keeps history readable even if a target is removed.

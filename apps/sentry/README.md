# Sentry

The monitoring service for [Pilotlight](../../README.md). A Go service that polls the workload's public health endpoint on an interval, stores check history in DynamoDB, and reports the live ECS and RDS topology of both workload Regions through read-only AWS APIs.

Sentry runs in `eu-north-1`, outside both drill Regions, with its own VPC and its own Terraform state. A monitor that shares a failure domain with the workload it watches stops reporting at the moment the report matters, so this one is deployed as a separate system with a separate lifecycle. It keeps observing and recording through a complete regional failover.

<!-- Screenshots of the status UI go here. -->

## Endpoints

| Path | Description |
|---|---|
| `GET /healthz` | Store health, used by the ALB target group |
| `GET /targets` | The configured target list |
| `GET /status` | Latest check result and rolling 24-hour uptime |
| `GET /history?target={URL}&limit={1-500}` | Recent checks for an exact target URL |
| `GET /topology` | Live ECS and RDS state for the primary and secondary Regions |
| `GET /` | Status UI |

## Configuration

| Variable | Required | Default |
|---|---|---|
| `MONITORED_URL` | No | `http://localhost:8081/healthz` |
| `DYNAMODB_TABLE` | Deployed environments | Empty, which selects the in-memory store |
| `AWS_REGION` | When `DYNAMODB_TABLE` is set | None |
| `CHECK_INTERVAL_SECONDS` | No | `30` |
| `PORT` | No | `8080` |

Topology reads use explicit workload identifiers, not the sentry's own task metadata. Configure each Region as a complete group or leave it unset:

- `PRIMARY_AWS_REGION`, `PRIMARY_ECS_CLUSTER`, `PRIMARY_ECS_SERVICE`, `PRIMARY_DB_IDENTIFIER`
- `SECONDARY_AWS_REGION`, `SECONDARY_ECS_CLUSTER`, `SECONDARY_ECS_SERVICE`, `SECONDARY_DB_IDENTIFIER`

A partially configured Region is rejected at startup, so a missing variable surfaces immediately instead of showing as an unavailable Region.

## DynamoDB model

Single table, string keys named `pk` and `sk`.

- `pk`: `TARGET#<canonical URL>`
- `sk`: `CHECK#<UTC timestamp, fixed-width to nanoseconds>`
- `expires_at`: Unix epoch seconds, 30 days after the check, configured as the table TTL attribute

History and 24-hour uptime use `Query` against the target partition with time-sortable sort keys, so no operation scans the table. The sort key is fixed width because a variable-width timestamp would sort a whole-second check after fractional-second checks in the same second.

## Implementation notes

HTTP keep-alives are disabled on the checker's client. The monitored hostname resolves to a different Region after a failover, and a pooled connection at a 30 second interval never idles out of Go's default pool, so a reused connection would keep reporting on the pre-failover Region. Forcing a fresh connection forces a fresh DNS lookup on every check.

A region whose AWS configuration fails to load keeps nil clients rather than failing startup, so one unreachable Region degrades its own card instead of taking down the whole topology view.

Task roles are read-only against ECS and RDS, with writes scoped to the sentry's own DynamoDB table.

## Local development

From the repository root:

```bash
docker compose up --build
```

Or directly:

```bash
go run ./cmd/sentry
```

Open `http://localhost:8080`. Local mode monitors `http://localhost:8081/healthz` and keeps checks in memory. Topology comes from a static fixture, since live ECS and RDS state only exists once deployed.

```bash
go test ./...
```

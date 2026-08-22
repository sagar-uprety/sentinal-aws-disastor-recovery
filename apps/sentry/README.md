# Pilotlight Sentry

Repository implementation for isolated HTTP uptime sentry and status page; not yet deployed for M7. The sentry checks one canonical workload health URL, stores deployed history in DynamoDB, and exposes workload topology across production and disaster-recovery regions.

## Local start

```bash
go run ./cmd/sentinel
```

Open http://localhost:8080. Local mode monitors `http://localhost:8081/healthz` and stores checks in memory.

## Endpoints

| Path | Description |
|------|-------------|
| `GET /healthz` | Store health |
| `GET /targets` | Configured target list containing exactly one URL |
| `GET /status` | Latest result and rolling 24-hour uptime |
| `GET /history?target={URL}&limit={1-500}` | Recent results for exact target URL |
| `GET /topology` | Explicit production and secondary ECS/RDS resource state |
| `GET /` | Static status UI |

## Configuration

| Variable | Required | Default |
|----------|----------|---------|
| `MONITORED_URL` | No | `http://localhost:8081/healthz` |
| `DYNAMODB_TABLE` | Production | Empty, enabling memory store |
| `AWS_REGION` | When `DYNAMODB_TABLE` is set | None |
| `CHECK_INTERVAL_SECONDS` | No | `30` |
| `PORT` | No | `8080` |

Topology uses explicit workload identifiers and never sentry ECS task metadata. Configure each region as a complete group or leave it unset:

- `PRIMARY_AWS_REGION`, `PRIMARY_ECS_CLUSTER`, `PRIMARY_ECS_SERVICE`, `PRIMARY_DB_IDENTIFIER`
- `SECONDARY_AWS_REGION`, `SECONDARY_ECS_CLUSTER`, `SECONDARY_ECS_SERVICE`, `SECONDARY_DB_IDENTIFIER`

## DynamoDB data model

Table keys are strings named `pk` and `sk`.

- `pk`: `TARGET#<canonical URL>`
- `sk`: `CHECK#<UTC RFC3339Nano timestamp>`
- `expires_at`: Unix epoch seconds, 30 days after check time; configure this as table TTL attribute

History and 24-hour uptime use DynamoDB `Query` against the target's partition and time-sortable keys. The sentry never scans table.

Drill lifecycle events are not stored here. `scripts/drills/drill-lib.sh` writes timestamped events to a local plain-text `DRILL_LOG` file only, and `scripts/drills/measure.sh` reads that file to compute RTO/RPO. There is no sentry-side event storage or timeline UI.

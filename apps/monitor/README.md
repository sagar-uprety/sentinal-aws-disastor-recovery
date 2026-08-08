# Pilotlight Monitor

Repository implementation for isolated HTTP uptime monitor and status page; not yet deployed for M7. The monitor checks one canonical workload health URL, stores deployed history in DynamoDB, and exposes workload topology across production and disaster-recovery regions.

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
| `GET /topology` | Explicit production and DR ECS/RDS resource state |
| `GET /` | Static status UI |

## Configuration

| Variable | Required | Default |
|----------|----------|---------|
| `MONITORED_URL` | No | `http://localhost:8081/healthz` |
| `DYNAMODB_TABLE` | Production | Empty, enabling memory store |
| `AWS_REGION` | When `DYNAMODB_TABLE` is set | None |
| `CHECK_INTERVAL_SECONDS` | No | `30` |
| `PORT` | No | `8080` |

Topology uses explicit workload identifiers and never monitor ECS task metadata. Configure each region as a complete group or leave it unset:

- `PROD_AWS_REGION`, `PROD_ECS_CLUSTER`, `PROD_ECS_SERVICE`, `PROD_DB_IDENTIFIER`
- `DR_AWS_REGION`, `DR_ECS_CLUSTER`, `DR_ECS_SERVICE`, `DR_DB_IDENTIFIER`

## DynamoDB data model

Table keys are strings named `pk` and `sk`.

- `pk`: `TARGET#<canonical URL>`
- `sk`: `CHECK#<UTC RFC3339Nano timestamp>`
- `expires_at`: Unix epoch seconds, 30 days after check time; configure this as table TTL attribute

History and 24-hour uptime use DynamoDB `Query` against the target's partition and time-sortable keys. The monitor never scans table.

Drill lifecycle events are not stored here. `scripts/drill-lib.sh` writes timestamped events to a local plain-text `DRILL_LOG` file only, and `scripts/measure.sh` reads that file to compute RTO/RPO. There is no monitor-side event storage or timeline UI.

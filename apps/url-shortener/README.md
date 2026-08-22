# URL Shortener Workload

Repository implementation for small PostgreSQL-backed drill workload; not yet deployed for M7. It creates short links through a token-protected API and serves public redirects. Monitoring, AWS topology, drill events, pulse records, and write-probe endpoints deliberately do not belong here.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Database-backed readiness |
| POST | `/links` | Create a link with an operator bearer token |
| GET | `/links` | List the 50 newest links |
| GET | `/{slug}` | Redirect to the stored destination |
| GET | `/` | Minimal browser interface |

Create a link:

```bash
curl --fail-with-body \
  --request POST \
  --header "Authorization: Bearer $LINK_CREATE_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"slug":"before-drill","destination_url":"https://example.com/recovered"}' \
  http://localhost:8081/links
```

## Configuration

Use either `DATABASE_URL` or all of `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`. `LINK_CREATE_TOKEN` is required and must contain at least 16 characters. `PORT` defaults to `8080`.

Production injects database credentials and the creation token from SSM Parameter Store. Tokens never appear in browser assets, logs, Terraform state, or image layers.

## Design Intent

Normal URL-shortener behavior supplies drill evidence: a primary-created link must survive failover, and a secondary-created link must survive failback. Infrastructure remains the interesting part.

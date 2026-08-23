# URL Shortener

The workload under test in [Pilotlight](../../README.md). A small PostgreSQL-backed Go service that creates short links behind a bearer token and serves public redirects.

Drill scripts use its links to check for data loss. They create links with known slugs, then look for them on the other side: a link created on the primary before an outage must be readable from the secondary after promotion, and a link created on the secondary during the outage must be readable from the primary after failback.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Readiness, backed by a database ping |
| POST | `/links` | Create a link, requires an operator bearer token |
| GET | `/links` | List recent links, newest first |
| GET | `/{slug}` | Redirect to the stored destination |
| GET | `/` | Minimal browser interface |

`GET /links` returns 50 links by default. Pass `?limit=` to request up to 1000, which drill scripts use so that an older evidence link stays within the returned page.

Create a link:

```bash
curl --fail-with-body \
  --request POST \
  --header "Authorization: Bearer $LINK_CREATE_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"slug":"before-drill","destination_url":"https://example.com/recovered"}' \
  http://localhost:8081/links
```

Slugs are 3 to 32 characters of letters, numbers, underscores, or hyphens. Destinations must be canonical HTTP or HTTPS URLs without embedded credentials. A duplicate slug returns 409.

## Configuration

| Variable | Required | Default |
|---|---|---|
| `DATABASE_URL` | Either this or the `DB_*` set | None |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Either this set or `DATABASE_URL` | None |
| `LINK_CREATE_TOKEN` | Yes, minimum 16 characters | None |
| `PORT` | No | `8080` |

`DATABASE_URL` suits local development. Deployed environments supply the five `DB_*` variables, which ECS injects from SSM Parameter Store. Setting both forms at once is rejected at startup.

Credentials are read from SSM at task start and never appear in browser assets, logs, Terraform state, or image layers.

## Implementation notes

The service runs `CREATE TABLE IF NOT EXISTS` on every start, so a freshly promoted replica reaches the expected schema without a manual migration step. That statement is DDL, which a read-only replica rejects, so tasks must not start against a replica that has not been promoted. The recovery workflows keep the secondary at zero desired count until promotion completes for exactly this reason.

The bearer token is compared in constant time, and the comparison checks length first so that only the token's length can be inferred from response timing.

## Local development

From the repository root:

```bash
docker compose up --build
```

The service listens on `localhost:8081` against a local PostgreSQL container.

```bash
go test ./...
```

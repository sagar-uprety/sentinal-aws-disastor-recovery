# Cloudflare MCP Setup

Added for the M4 Route53 delegation task: creating the `sentinel.sagaruprety.com.np`
hosted zone in Route53 requires adding NS delegation records to the existing
Cloudflare-managed `sagaruprety.com.np` zone, which lives outside AWS.

## Configuration

Added as a project-local (not committed, not shared) HTTP MCP server:

```
claude mcp add --transport http cloudflare https://mcp.cloudflare.com/mcp
```

This is Cloudflare's own remote MCP server — the general API server, not one
of the narrower product-specific servers (e.g. `dns-analytics.mcp.cloudflare.com`,
which is read-only analytics). It fronts the full Cloudflare API (DNS, zones,
Workers, R2, Zero Trust, ...) through two tools (`search`, `execute`) behind
OAuth, scoped per-connection to whatever the authorizing user grants.

Config lives in `~/.claude.json` under this project's entry, scope `local`
(default) — not `.mcp.json`, so it isn't committed to the repo or shared with
anyone who clones it. It stores OAuth tokens tied to a personal Cloudflare
account and has no reason to travel with the code.

## Authentication

OAuth requires a real interactive terminal (it runs a localhost callback
server and waits for the browser redirect), so it can't be completed
non-interactively. Run directly in a terminal:

```
claude mcp login cloudflare
```

On the Cloudflare consent screen, grant **DNS edit scoped to the
`sagaruprety.com.np` zone only** — not full account access. This server
otherwise exposes every Cloudflare product; least-privilege here matters.

Check connection status any time with `claude mcp list`.

## What it's used for

Adding the NS delegation records so `sentinel.sagaruprety.com.np` resolves
through Route53 instead of Cloudflare:

1. Route53 creates the `sentinel.sagaruprety.com.np` hosted zone (Terraform)
   and returns its 4 NS nameservers.
2. Via this MCP connection: add an `NS` record for `sentinel` in the
   `sagaruprety.com.np` Cloudflare zone, pointing at those 4 nameservers.
3. Verify with `dig NS sentinel.sagaruprety.com.np` (expect the Route53
   nameservers) and `dig A sentinel.sagaruprety.com.np` (expect it to
   resolve through Route53, not Cloudflare).

## Removing it later

```
claude mcp remove cloudflare
```

Credentials are stored per-machine by the CLI; removing the server doesn't
revoke the Cloudflare-side authorization — revoke that from the Cloudflare
dashboard (My Profile → API Tokens / Authorized Applications) if it's no
longer needed after M4.

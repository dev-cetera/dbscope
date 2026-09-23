# dbscope_pg_proxy

A small standalone Dart binary that lets the DBScope web build talk to
any Postgres — local, Google Cloud SQL, AWS RDS, Neon, Supabase, etc.

Browsers cannot speak the Postgres wire protocol directly (no raw TCP).
This proxy bridges the gap: the web app opens a **WebSocket** to the
proxy; the proxy holds the **Postgres connection** and forwards SQL.

## Quick start (local Postgres)

```sh
dart run packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart \
    --port 8765
```

In the web build's *New connection → PG Proxy* dialog, enter:

| Field          | Value                                                |
|----------------|------------------------------------------------------|
| Proxy URL      | `ws://127.0.0.1:8765`                                |
| Host/port/db   | `localhost` / `5432` / your db                       |
| Username/pass  | your Postgres credentials                            |

## Pointing at Cloud SQL / RDS / Neon / Supabase

Run the proxy from a host that **already has network reach** to the
managed DB — your laptop (through a Cloud SQL Auth Proxy, a bastion, or
the public endpoint), a small VM in the same VPC, a Cloud Run instance,
etc. Then:

- **Host / port / db / user / pass** are the managed DB's own credentials.
- **SSL mode** should be `require` for any provider that enforces TLS
  (Cloud SQL, RDS in modern configs, Neon, Supabase). Use `verify-full`
  if you've pinned a server cert; the proxy talks to Postgres, not to
  the browser, so this is the standard Postgres TLS story.

## Hardening for non-local use

The proxy is a thin pipe to a database. Anyone who can reach it can
issue any SQL the configured Postgres user is allowed to run. Treat it
exactly like exposing Postgres itself.

- **Bind to a trusted interface.** Default is `127.0.0.1`. Use
  `--host 0.0.0.0` only behind a firewall.
- **Front it with TLS.** Put a reverse proxy (Caddy, nginx, Cloudflare
  Tunnel) in front and serve `wss://` to the browser. The web build
  refuses mixed content — if your DBScope is served over `https://`
  you must use `wss://`.
- **Require a shared secret.** Pass `--shared-secret SECRET`; the web
  client echoes it on every `open` message. Without one, any browser
  that can reach the proxy can connect to your DB.
- **Constrain the origin.** Pass `--allow-origin https://your.host` so
  the proxy rejects WebSocket upgrades from other origins.
- **Use a least-privileged Postgres role.** The proxy never inspects or
  restricts the SQL it forwards.

## Wire protocol (JSON over WebSocket)

One WebSocket owns one Postgres connection for its lifetime.

| Direction        | Frame                                                      |
|------------------|------------------------------------------------------------|
| client → server  | `{type: open, host, port, database, username, password, sslMode, secret?}` |
| client → server  | `{type: execute, id, sql, positional?, named?}`            |
| client → server  | `{type: close}`                                            |
| server → client  | `{type: ready}` (after a successful open)                  |
| server → client  | `{type: result, id, columns: [{name, typeName}], rows, affected}` |
| server → client  | `{type: error, id?, code?, message, constraintName?}`      |

The wire encoder serializes `DateTime` as ISO-8601 UTC, byte arrays as
`{_b64: "..."}`, and falls back to `toString()` for unknown types.

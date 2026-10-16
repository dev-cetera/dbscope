# dbscope

A Flutter desktop database viewer and editor for macOS, Windows, and Linux. Browse schemas, run queries, edit rows, and navigate foreign-key relationships across huge tables.

It connects to:

- **Postgres** (14–17) directly over TCP.
- **Cloud SQL for Postgres** through a Cloud SQL Auth Proxy that dbscope starts and stops for you (needs `gcloud auth login`).
- **Postgres over HTTP** via the bundled `dbscope_pg_proxy` — the only backend in the web build.
- **Local SQLite** files (*File ▸ Open .db file…*).
- **SQLite inside an app on a USB-connected Android or iOS device**, pulled, edited and pushed back via `adb` / `devicectl`. Force-stop the app first: the file is a snapshot.

Connections can be shared as encrypted `.dbscopeconn` links (*File ▸ Import / Export connection link…*). API keys and passphrases are read from your shell profile (`~/.zshenv` by default, *File ▸ Environment…*), since apps launched from the Finder don't see your shell's exports.

## Getting started

Flutter is pinned to 3.47.7 (Dart 3.13.5) via FVM (see `.fvmrc`). Prefix commands with `fvm` to pick up the right SDK. The macOS build needs macOS 12 or later.

```
fvm flutter pub get
fvm flutter run -d macos     # or -d windows / -d linux
```

That's it - the app launches, and you add a connection profile from the UI.

## Other useful commands

```
fvm flutter analyze          # lint
fvm flutter test             # run tests
fvm flutter build macos      # or windows / linux / web
```

The macOS build runs without the App Sandbox (it shells out to `adb`, `xcrun` and `cloud-sql-proxy`), so it can't ship to the Mac App Store as is.

## Schema metadata (optional)

dbscope reads what the database already says about itself — Postgres
`COMMENT ON` for schemas, tables, columns and types, plus constraints,
indexes, defaults, triggers and RLS policies (right-click → *About …*). On
top of that, a database can carry optional **metadata** that tells dbscope
what the schema *means* and *who may see what*. Without it, nothing changes.

**Where it comes from** (merged; later wins on equal specificity):

1. Postgres comments (`COMMENT ON …`) — zero setup.
2. Metadata tables in the database, every one prefixed so it can't be
   mistaken for the application's own tables (a bare `roles` could be the
   app's access control): schema `dbscope` with `dbscope_metadata`,
   `dbscope_access_roles`, `dbscope_access_role_members` and
   `dbscope_access_grants` on Postgres; `_dbscope_metadata`, … on SQLite.
   *Metadata ▸ Initialize metadata tables…* shows the DDL first.
3. A metadata file (YAML or JSON) set per connection in *Metadata ▸
   Settings…* — reviewable in PRs, and the only option for databases you
   can't add tables to. `include: [other.yaml]` shares a base.
4. This machine's per-connection overrides (soft-delete column).

`fvm dart run tool/meta_to_sql.dart meta.yaml --replace --out meta.sql`
turns a file into SQL that creates the tables and loads it (psql-ready).

**Selectors** address everything: `*`, `schema`, `schema.table`,
`schema.table.column`, `query:<id>`, `query:<id>.<column>`. Segments are
literals, `"quoted literals"`, or globs (`*`, `*_internal`). The most specific
rule wins: a column selector beats a table selector; then literal > partial
glob > `*`.

**File shape**

```yaml
format: 1
rbac: { default: read, identity: claimed }   # access-control settings
meta:
  - { id: users.label, target: public.users, kind: display, rowLabel: "{name}" }
  - id: overdue
    kind: query
    label: Overdue items
    sql: SELECT id, name, due_at FROM items WHERE due_at < now()
roles:
  - { id: support, label: Support, capabilities: [export] }
members:
  - { role: support, principal: "pg:support_team" }   # or "user:me@example.com"
grants:
  - { id: g1, role: everyone, target: "*.*.password_hash", level: none }
```

**Kinds**

| Kind | What it does |
|---|---|
| `describe` | label, description, unit, examples, deprecation, enum value meanings — tooltips, inspector, DBML notes for the AI |
| `display` | `rowLabel` ("{name} ({status})"), `defaultSort` ("-created_at"), `defaultFilter`, `group` (sidebar folders), `renderer` (money, bytes, duration, timestamp, relative_time, color, url, json…) |
| `sensitive` | `excludeFromAi`, `excludeFromExport` |
| `policy` | `readOnly` + `reason`, `softDelete`, `touch` (stamped on edit), `pattern`/`min`/`max`, `danger: hardDelete` or `delete` |
| `link` | virtual FKs (`to`), polymorphic (`polymorphic: {by, table: lower, map}`), JSON-path ids, URL templates |
| `action` | right-click SQL: scope `global/table/row/cell/selection`, run `query/openTable/exec/url/copy`, placeholders `@row_<col>`, `@pk_<col>`, `@cell`, `@input_<name>`, `@rows_<col>` (always bound as parameters), `when`, `confirm`, `expectRows`, `roles` |
| `query` | named queries — sidebar *Queries & dashboards*; their result columns take every other kind via `query:<id>.<col>` |
| `chart` | line/area/bar/stacked_bar/pie/scatter/histogram/stat from a table (no SQL: `x`, `bucket`, `y: [{agg, column}]`, `series`, `range`, `rangeColumn`), a named query, or row-scoped SQL |
| `dashboard` | a grid of chart ids |
| `check` | SQL that should return no rows — *Metadata ▸ Run checks…* |
| `ai` | notes and example question→SQL pairs for the SQL assistant |

Charts exist only where the metadata defines them: there is no ad-hoc
"visualise any column", so what can be charted is decided in review.

**Access control.** Grant levels `none < masked < read < edit < full` per
selector; capabilities `query` (free SQL), `export`, `ai`, `exec` (write
actions), `manage`. Most specific grant wins across all of a user's roles;
among equals the most generous. `none` columns are never fetched, masked ones
come back as `NULL` and show `••••`. Identity: `pg:` principals are verified
by the login; `user:` principals are claimed (typed into Settings) and only
ever guardrails. Real enforcement is Postgres privileges — *Metadata ▸
Generate enforcement SQL…* writes the GRANT/REVOKE script and reports drift;
dbscope never runs it. Unreadable rules fail closed (read-only).

**Trust.** Metadata SQL (actions, queries, charts, checks, default filters)
runs only after you trust it on this machine; any change asks again and
marks what changed. Queries, charts, checks and query actions also run
inside a read-only transaction where the backend supports it (Postgres,
local SQLite); default and `openTable` filters become part of the grid's own
queries, so trust is their only guard.

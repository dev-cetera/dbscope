# Changelog

---

## 2026-11-03

- The connection dialog's Read-only switch now proposes a default and says why: on when the name says prod/live/main or the server is remote, off for a database on this machine; it stops following once you flip it (2026-11-03)
- Re-importing a connection link (or auto-connecting) for an open profile now reconnects when the host, user, password or other connection settings changed, instead of keeping the old connection (2026-11-03)
- Fix Postgres query result headers showing Type(oid:N) instead of the type name (2026-11-03)
- Fix job tabs showing a fast job as running forever when it finished before the tab subscribed (2026-11-03)
- Fix one window closing a stream (job progress, profile or metadata updates) belonging to another window (2026-11-03)
- Fix soft delete on SQLite, which wrote now(): it now writes CURRENT_TIMESTAMP (2026-11-03)
- Fix keyset paging stopping at the first NULL when sorting by a nullable column (2026-11-03)
- Fix table tabs ignoring a connection's read-only setting: the grid is no longer editable on read-only connections (2026-11-03)
- Fix CSV export leaving a bare carriage return unquoted, which split the row in two (2026-11-03)
- Hide the .db export button on the web build, where it did nothing (2026-11-03)
- Fix copy jobs blocking every other query on the target profile while they run: the target now gets its own connection (2026-11-03)
- Fix .db export destroying an existing file when the export fails, and failing on duplicate column names (they become id_2, …) (2026-11-03)
- Fix cell edits on phones with SQLite older than 3.39 (Android 13 and earlier) failing on IS NOT DISTINCT FROM (2026-11-03)
- Fix two windows saving to the project file or query history at once losing one of the changes (2026-11-03)
- Fix an interrupted project-file save wiping saved connections and queries: writes are atomic and an unreadable file is kept aside as .corrupt-<time> (2026-11-03)
- Fix the Navigator's row filter on SQLite, which used Postgres-only ::text ~* syntax (2026-11-03)
- Fix Export schema as DBML on SQLite: it no longer queries pg_type and labels the file as SQLite (2026-11-03)
- Fix the date/time picker dropping the seconds (and zone) of a timestamp or time cell (2026-11-03)
- Fix metadata SQL with typed placeholders (@id:int8, $1::int8) failing on SQLite (2026-11-03)
- Fix @me_principal binding NULL when no identity is known: actions now say they need it, and on Postgres it falls back to the login (claimed emails are lowercased) (2026-11-03)
- Fix pressing Cmd/Ctrl+Enter twice in a Query tab running two queries at once and losing the Stop button (2026-11-03)
- Fix the row inspector saving an open edit into a different row after you select another row: switching rows now closes the editor (2026-11-03)
- Fix SQLite metadata queries that start with a comment, or a RETURNING after a newline, silently returning no rows (2026-11-03)
- Fix importing a hostile .dbscopeconn file hanging in the key derivation or failing with a raw error: iteration count, nonce and tag sizes are now checked (2026-11-03)
- Fix the timestamp renderer showing a date-only value one day early for viewers east of UTC (2026-11-03)
- Fix metadata charts and queries on SQLite ignoring their timeout: a runaway statement is now stopped at the deadline (2026-11-03)
- Fix the AI assistant's read-only check letting through data-modifying CTEs, EXPLAIN ANALYZE DELETE and SELECT INTO, which could write on the pg proxy and on phones (2026-11-03)
- Fix profiles named like Liverpool, Olive or Maintenance defaulting to read-only: the prod/live/main guess now needs a whole word (2026-11-03)
- Fix connections leaking: a profile deleted in another window now closes this window's connection, connecting an already-open profile reuses it, and two server-side opens of one profile share one connection (2026-11-03)
- Fix the connection dialog's password: you can now tick 'Forget the saved password' to delete it from the keychain (leaving the field empty still keeps it) (2026-11-03)
- Fix scripts/add_changelog_line.sh refusing every line when CHANGELOG.md has no --- header rule: it now adds the rule itself (2026-11-03)
- Fix inline cell editing in table grids: the editor now takes keyboard focus on double-click / Enter, stays open while you type (it used to save and close after one character), lets arrow keys and Cmd-A work inside the field, and saves on Enter, Tab or clicking another cell (Esc discards) (2026-11-03)
- Landing page: canonical URL, fuller social tags, SoftwareApplication and FAQPage structured data, a visible FAQ, sitemap.xml and llms.txt, checked on every Pages deploy by scripts/check_site_seo.sh (2026-11-03)

## 2026-10-19

- Launching with `DBSCOPE_AUTO_HOST` (plus `DBSCOPE_AUTO_DATABASE`/`DBSCOPE_AUTO_USERNAME`/etc., or `DBSCOPE_AUTO_CLOUDSQL_INSTANCE` for Cloud SQL) set auto-connects to that database on startup instead of restoring the last GUI connection — a fully command-line launch, no "Import connection link" step. See `lib/connection/cli_auto_connect.dart`; the compledo repo's `backend/scripts/dbscope/start_dbscope.sh local|dev|prod` drives it. (2026-10-19)

## 2026-10-16

- Flutter 3.47.7 / Dart 3.13.5 (was 3.41.9 / 3.11.5). The app and app-specific plugin packages now require Dart `^3.13.5`; the new SDK's lint fixes are applied, and three deprecated lint rules are dropped. The macOS build now requires **macOS 12** (was 10.15) and pulls plugins through Swift Package Manager; `desktop_multi_window` still comes through CocoaPods, which Flutter warns will eventually be an error. (2026-10-16)
- Table view: loading more rows no longer shows each page twice, deleting a row no longer removes the row below it too, and inserted rows no longer appear twice (the grid and the tab were sharing one row list). The selection now stays on its row after a delete, insert or trim. (2026-10-16)
- Table view: a page fetched before a sort or refresh is no longer added onto the new results. Pressing Stop no longer stops paging for good. (2026-10-16)
- Opening the JSON/code editor no longer breaks every other window's connection to the host, and an editor opened from a secondary window now returns its result. (2026-10-16)
- Postgres enum columns whose names contain "int" (e.g. `appointment_status`), plus `point` and range types, are no longer treated as integers, so editing them works. (2026-10-16)
- Copy table: reads the source through a cursor in one consistent snapshot on its own connection, so rows are no longer skipped or duplicated. Large tables no longer slow down quadratically, and tables with 132 or more columns no longer fail. (2026-10-16)
- AI-generated SQL now runs inside a read-only transaction on Postgres and local SQLite. The Query tab accepts `DO $$ … $$`, function bodies and `E'…'` strings, and SQLite connections get SQLite's lexing rules. (2026-10-16)
- Smoother sidebar, inspector and column resizing: the app no longer rebuilds its theme on every change, column resize keeps up with the pointer, and the resize handles are easier to grab. Query-tab column widths no longer reset when you click a row. (2026-10-16)
- Smaller fixes: the sidebar listing can't be overwritten by a slow load for the previous connection; the server keeps profile passwords after settings changes, so copy jobs keep working; open tabs, including unsaved SQL, are saved on quit; query history survives a damaged file and is written atomically; the menu bar's "Hide/Show sidebar" and theme marker update; and the web build compiles again. (2026-10-16)

## 2026-10-15

- New app icon: a flat "db" monogram (two rings sharing a stem, so it also reads as binoculars), cream on vermilion, replacing the shaded microscope-over-spreadsheet. `assets/icon/dbscope_icon.svg` is the source; the macOS icon set, web icons, maskable icons and favicon are rendered from it. (2026-10-15)

## 2026-10-11

- Metadata tables renamed to `dbscope_metadata`, `dbscope_access_roles`, `dbscope_access_role_members`, `dbscope_access_grants` (SQLite: `_dbscope_*`) so they can't be mistaken for an app's own RBAC tables; existing `dbscope.meta`/`roles`/`role_members`/`grants` tables are not read any more — re-create and reload them. (2026-10-11)
- Descriptions render as coloured Markdown in a width-capped hover card (fine print below a rule); hovering or right-clicking anywhere on a column header, or an inspector field name, explains the column. (2026-10-11)
- Removed the ad-hoc "Visualise column": charts exist only where metadata defines them. (2026-10-11)
- Schema metadata: native Postgres descriptions (comments, constraints, indexes, triggers, policies), optional metadata tables/file with descriptions, display, links, right-click actions, named queries, charts and dashboards, checks, and role-based access control with trust, read-only fencing and enforcement-SQL generation; `tool/meta_to_sql.dart`. (2026-10-11)
- data_grid: hidden columns, header tooltips/markers, context-menu extras for the clicked cell; default renderer typed by the grid. schema_viewer: dashed edges. (2026-10-11)

# Changelog

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

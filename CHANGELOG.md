# Changelog

## 2026-10-11

- Metadata tables renamed to `dbscope_metadata`, `dbscope_access_roles`, `dbscope_access_role_members`, `dbscope_access_grants` (SQLite: `_dbscope_*`) so they can't be mistaken for an app's own RBAC tables; existing `dbscope.meta`/`roles`/`role_members`/`grants` tables are not read any more — re-create and reload them. (2026-10-11)
- Descriptions render as coloured Markdown in a width-capped hover card (fine print below a rule); hovering or right-clicking anywhere on a column header, or an inspector field name, explains the column. (2026-10-11)
- Removed the ad-hoc "Visualise column": charts exist only where metadata defines them. (2026-10-11)
- Schema metadata: native Postgres descriptions (comments, constraints, indexes, triggers, policies), optional metadata tables/file with descriptions, display, links, right-click actions, named queries, charts and dashboards, checks, and role-based access control with trust, read-only fencing and enforcement-SQL generation; `tool/meta_to_sql.dart`. (2026-10-11)
- data_grid: hidden columns, header tooltips/markers, context-menu extras for the clicked cell; default renderer typed by the grid. schema_viewer: dashed edges. (2026-10-11)

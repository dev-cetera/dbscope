# Bugs

Every open bug, suspected or confirmed. Usually something an agent or a person ran into while doing something else and couldn't fix on the spot. Newest first.

This file is for things with a real failure: wrong output, a crash, lost data, a check that can never fire. Work that has no failure goes in `TODO.md`. Fixed bugs are deleted from here and get a line in `CHANGELOG.md`.

Don't read this file whole. Search it for the file or symbol first:

```sh
rg -n --max-count 5 '<file or symbol>' BUGS.md
```

## Entry format

```text
### <one-line claim of what's wrong>

- **Where.** `path/to/file:123` (`SymbolName`)
- **Failure.** Concrete input or state, then the wrong output, crash or loss.
- **Noticed.** YYYY-MM-DD, while <what you were doing>.
- **Confidence.** suspected | likely | confirmed
- **Why not fixed on the spot.** For example: outside the task, needs a decision, would blow up the diff.
```

## Open

<!-- New entries go here, newest first. -->

### Clearing a connection's password cannot clear it: the stored secret survives and is used on the next connect

- **Where.** `lib/connection/profile_store.dart:24-33` (`save`) writes a password only `if (profile.password.isNotEmpty)`, and `lib/server/services/profile_service.dart:77-92` (`_upsert`) puts the old password back whenever the incoming profile's password is empty. `SecureStore.deletePassword` (`lib/connection/secure_store.dart:32`) has exactly one caller, `ProfileStore.delete` (`profile_store.dart:35-37`), which runs only when the whole profile is removed.
- **Failure.** The connection dialog opens with the password field empty (profiles reach the window with `password: ''` — `profile_service.dart` comment at `:81`), so the only way to express "forget the password" is to leave or make it empty; both are treated as "keep the stored one" and no RPC ever deletes the keychain entry. After the database password is rotated, the user clears the field, saves, sees an empty box, reconnects — and the app still authenticates with the old password, failing with `password authentication failed` while the dialog shows no password at all. The stale secret also stays in the login keychain indefinitely for a profile that no longer uses one.
- **Noticed.** 2026-11-03, while auditing where profile secrets are written and deleted.
- **Confidence.** confirmed (no delete path is reachable from the dialog: both the service and the store skip empty passwords, and the only delete call is profile removal).
- **Why not fixed on the spot.** Audit only; it needs a sentinel ("keep" vs "clear") in the profile JSON or an explicit Clear button that calls `SecureStore.deletePassword`, which is an API change in `ConnectionProfile`/`profile.*` RPC.

### A profile deleted in another window drops this window's open connection without closing it

- **Where.** `lib/connection/registry.dart:158` (`_mergeProfiles`): `_states.removeWhere((id, _) => !keep.contains(id))` throws the `_ConnState` away, and with it the only reference to its `DbExecutor`. The same-window path does it properly — `removeProfile` awaits `_closeState(_states[id])` before removing.
- **Failure.** A window has profile A open (its own Postgres socket, or the Cloud SQL proxy it spawned). The user deletes A in another window; `profile.changed` arrives, `_mergeProfiles` drops the state, and the socket/proxy is never closed — the window shows nothing connected, but the database still sees a live session and the proxy process keeps running until the app quits. Repeat on a Cloud SQL instance with a low connection limit and later connects start failing on the server side while the app reports no connections.
- **Noticed.** 2026-11-03, while auditing the profile.changed merge path against the same-window delete path.
- **Confidence.** confirmed (the remove-where has no `_closeState`, and `_ConnState` is the only holder of the executor).
- **Why not fixed on the spot.** Audit only; `removeWhere` cannot await, so the fix needs a collected list of dropped states closed after the merge, plus a test in `test/connection_registry_test.dart` (if absent, a new one).

### Connecting to a profile that is already open opens a second connection and abandons the first

- **Where.** `lib/connection/registry.dart:302-357` (`_connect`) guards only `state.isConnecting`, never `state.isConnected`, and assigns `state.executor = opened.executor` at `:356` without closing the previous one. `setActive` (`:261`) returns early when `id == _activeId`, but `connectProfile` (`:284-300`) calls `connectActive` afterwards regardless, and `connectActive` (:276) has no connected check either.
- **Failure.** Re-importing a connection link whose profile id is the active, already-connected profile (the documented way to refresh a link's credentials) runs `connectProfile` → `addProfile` → `setActive` (no-op) → `connectActive` → `_connect`, which dials a second socket and overwrites `state.executor`. The first executor is never closed: it keeps its Postgres session (or Cloud SQL proxy) alive, keeps the metadata `Expando` pointing at it, and anything still holding that executor (a running query, `DbmlCache.warm`) writes through a connection the window no longer owns. The same happens for any code path that calls `connectActive` on a connected profile — the guard that would prevent it lives one level up, in `setActive`.
- **Noticed.** 2026-11-03, while tracing the connection-link import flow into the registry.
- **Confidence.** likely (the missing guard is plain in `_connect`; how often the UI reaches it while connected depends on the caller, and the link flow is the one path I traced that can).
- **Why not fixed on the spot.** Audit only; the fix is a policy question — reuse the live executor, or close the old one before assigning — and closing first would break callers holding the old executor.

### A profile named after any word containing "prod", "live" or "main" silently opens read-only

- **Where.** `lib/connection/profile.dart:9-12` (`readOnlyHeuristic = RegExp('prod|live|main', caseSensitive: false)`) applied at `:91` (`readOnly ?? readOnlyHeuristic.hasMatch(name)`): an unanchored substring test against the profile's display name.
- **Failure.** Creating a profile named `Liverpool`, `Olive`, `Domain admin`, `Maintenance` or `Deliveries` gets `readOnly: true` with no mention in the dialog (`_readOnly = i?.readOnly ?? true` is the dialog's own default, so the toggle looks like a deliberate choice). Every edit, delete, soft delete and metadata action on that connection is then refused as read-only, and nothing visible explains why — the user has to find the toggle. The heuristic is also dropped entirely on reload (`fromJson` passes `readOnly: json['readOnly'] ?? false`), so the same name behaves differently before and after a restart.
- **Noticed.** 2026-11-03, while auditing how a profile's read-only flag is initialised.
- **Confidence.** confirmed for the match (unanchored, case-insensitive substring on the name); the visible refusal depends on the name a user picks.
- **Why not fixed on the spot.** Audit only; a whole-word or prefix match (or asking in the dialog) changes which existing profiles open read-only, so it needs a decision rather than a quiet regex tweak.

### The AI assistant's read-only gate passes a data-modifying CTE and `EXPLAIN ANALYZE` on DML, so on the pg proxy and on-device SQLite an "AI" query can still write

- **Where.** `lib/ai/sql_assistant.dart:252-269` (`enforceReadOnly`) only rejects a second statement and checks the first word against `{'SELECT', 'WITH', 'EXPLAIN', 'VALUES'}` (`:263`); it never looks for `INSERT`/`UPDATE`/`DELETE`/`MERGE` inside a `WITH`. It is called from `:96` before the SQL is returned. The hole is already named in a doc comment at `lib/query/query_tab_view.dart:87-93`. The fallback fence is `executeReadOnly` (`lib/meta/read_only_exec.dart:109`), which runs the SQL unfenced when `capabilities.transactions` is false — the pg proxy and the on-device sqflite executor report exactly that (`docs/architecture.md`, "on-device SQLite plugin" and "Schema metadata" → metadata SQL is untrusted code).
- **Failure.** A user asks the assistant for something and the provider answers `WITH d AS (DELETE FROM public.items RETURNING *) SELECT * FROM d`, or `EXPLAIN ANALYZE DELETE FROM public.items`: both pass the gate, because the first word is allowed and there is no second statement. On a Postgres profile the read-only transaction rejects the write, so the run fails harmlessly — but on a pg-proxy profile and on a USB-connected phone (`capabilities.transactions == false`) the statement runs for real: rows are deleted, and on the phone `DeviceSqliteExecutor` pushes the modified file back to the device on the next write. `EXPLAIN ANALYZE` is the same problem without a CTE: it executes the statement it explains.
- **Noticed.** 2026-11-03, while auditing the assistant's gate against the metadata fence in the SQL-safety invariants.
- **Confidence.** confirmed (the allowed set and the missing DML scan are visible at `sql_assistant.dart:263-268`, and the unfenced branch is an explicit `return run()`).
- **Why not fixed on the spot.** Audit only; whether to scan the whole statement for DML with the existing lexer (`lib/util/sql_parse.dart`), to refuse `EXPLAIN` without `ANALYZE`, or to refuse AI queries outright on unfenced backends is a security decision, and each option rejects some SQL someone may legitimately want.

### Two callers opening the same profile at once each dial their own connection, and the loser is leaked

- **Where.** `lib/server/services/connection_service.dart:93-107` (`_open`) checks `entry.executor?.isOpen` at `:101`, awaits `_openWithPlugin` at `:106`, and only then assigns `entry.executor` at `:110`; there is no in-flight guard or pending map. Both entry points can overlap: `obtain` (`:65-75`, used by server-side jobs) and the `connection.open` RPC (`:36-40`); `closeAll` (`:150-154`) only closes what `_entries` still holds.
- **Failure.** Two jobs (or a job and a window's connect) call `obtain()` for one profile before the first socket finishes connecting. Both see no open executor, both call `_openWithPlugin`, and the second assignment overwrites the first: the first `DbExecutor` is never closed, so it stays connected for the life of the process, and `connection.close` cannot stop it — it cancels only the stored executor, which is the loser's. Anything the losing job holds on that socket (a transaction from `CopyTableJob`'s snapshot, a long query) keeps running invisibly, and `connection.state:<id>` flaps `connecting → connected` twice.
- **Noticed.** 2026-11-03, while auditing the server-side connection lifecycle against the job service's `obtain` path.
- **Confidence.** confirmed (no guard exists between the `isOpen` check and the assignment, and the awaits at `:94` and `:106` are real yield points).
- **Why not fixed on the spot.** Audit only; single-flighting opens changes lifecycle behaviour (a second caller should wait on the first open, or be refused) and needs a test in `test/server_test.dart`.

### On SQLite, a metadata query's timeout is silently ignored, so a runaway chart keeps running and blocks every other metadata query on the connection

- **Where.** `lib/meta/read_only_exec.dart:98-134` (`executeReadOnly`) — the SQLite branch (`:112-121`) sets `query_only` and runs the statement, but `timeout` is only used in the Postgres branch (`:128-131`, `SET LOCAL statement_timeout`). The statement runs while holding the per-executor metadata-session lock (`withMetaSession`, `:46-62`, taken at `:111`), whose tail future every later metadata caller awaits. `lib/meta/charts/chart_data.dart:104-113` promises the opposite in a comment — "The server cancels at [timeout] (statement_timeout inside the read-only fence)" — and abandons only its own future.
- **Failure.** A chart on a local `.db` whose SQL degenerates (a cartesian join, a `LIKE '%x%'` over a big table) passes `chart.timeoutMs`; after the grace period the view says the chart "took longer than 30s and was abandoned", but the `sqlite3` statement is still executing inside the `PRAGMA query_only` fence and nothing interrupts it. Because the abandoned call still holds the session lock, the next chart, named query or metadata action on that connection waits on `previous` and looks hung too, and a second Stop cannot reach the first query (`cancelToken` is not passed here either).
- **Noticed.** 2026-11-03, while auditing the chart runner's timeout against the fence implementation.
- **Confidence.** confirmed (the parameter is unused outside the Postgres branch, and no `sqlite3_interrupt`/connection-close path exists).
- **Why not fixed on the spot.** Audit only; SQLite has no `statement_timeout`, so the fix needs a policy — a timer plus `interrupt` on the underlying `sqlite3` connection, or repair-by-reopen — and that changes what a failed chart does to the window's connection.

### A `date`-only value rendered with the `timestamp` renderer shows the previous day for a viewer east of UTC

- **Where.** `lib/meta/value_format.dart:73-79` (`_dateTime`) — the zone test at `:76` is `RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$')`, which matches the trailing `-01` of a plain `2024-01-01`, so `hasZone` is true and the `Z` that `:78` appends for unzoned timestamps is skipped; `DateTime.tryParse` then returns **local** midnight. `formatTimestamp` (`:130-141`) converts with `t.toUtc()` (`:141`) unless `utcOffset`/`local` is set.
- **Failure.** Metadata `display.renderer: timestamp` (or `relativeTime`) on a `date` column, from SQLite or any backend that returns the date as text: the stored `2024-01-01` is parsed as local midnight and then shown as UTC, so on a machine at +10:00 it renders `2023-12-31 14:00:00 UTC`, and with `format: date` as `2023-12-31` — one day earlier than the value in the database. On a UTC-5 machine the same row renders `2024-01-01 05:00:00 UTC`. A full timestamp without a zone is handled correctly; only the date-only shape trips the regex, and the file's own contract says an unzoned value is meant to be read as UTC.
- **Noticed.** 2026-11-03, while auditing the metadata renderers' date parsing.
- **Confidence.** confirmed for the parse (date-only text ends in `-DD`, `DateTime.parse` reads a date-only string as local); the visible off-by-one depends on the viewer's zone, so it looks correct to a UTC user.
- **Why not fixed on the spot.** Audit only; tightening the zone regex (require `Z`, or `±hh:mm`) and deciding that a date-only string means UTC midnight both change what existing timestamps render as, so it needs a call on the intended contract.

### A connection link's `iterations` field has no bound and its nonce no length check, so one imported file can hang or crash the import

- **Where.** `lib/connection/connection_link.dart:128` reads `iterations` straight out of the file and passes it to `_deriveKey` (`:136`, `:151-160`); `:130-132` accept any base64 length for the nonce, salt, ciphertext and tag. `decode` only catches `SecretBoxAuthenticationError` (`:139-149`).
- **Failure.** A `.dbscopeconn` — a file people are expected to pass between machines — that says `"iterations": 2000000000` blocks the isolate in PBKDF2 for hours with no progress and no cancel, from a single File ▸ Import. `"iterations": 0` or a one-byte `nonce` instead make `Pbkdf2` / `AesGcm.decrypt` throw `ArgumentError`, which `decode` does not map, so the dialog reports a raw exception rather than "Not a valid connection file." (the same class of file, a hand-edited or hostile link, also reaches `ConnectionProfile.fromJson` unvalidated).
- **Noticed.** 2026-11-03, while auditing the connection link's decode path for hostile input.
- **Confidence.** likely (the missing checks are plain in the code; which exception the crypto package raises for `iterations: 0` and for a short nonce was not run here).
- **Why not fixed on the spot.** Audit only; it needs a ceiling on `iterations` (and a decision on whether to keep honouring a file's own value at all) plus an explicit mapping of crypto `ArgumentError`s to `FormatException`.

### On SQLite a bound metadata query that starts with a comment (or a parenthesis) returns no rows, and no error

- **Where.** `lib/db/sqlite_executor.dart:131-148` (`_statementProducesRows`) decides whether the prepared statement is a query purely from its leading keyword — `SELECT`, `WITH`, `PRAGMA`, `VALUES`, `EXPLAIN`, or `' RETURNING '` — and `:102-120` sends everything else down `statement.execute(...)`, which discards any result set and returns `affectedRows: _db.updatedRows`. Bound (named or positional) SQL reaches this path from `lib/meta/read_only_exec.dart:100-107`, which passes metadata SQL verbatim; nothing strips leading comments before execution — `stripCommentsAndLeading` is only used by the AI validator (`lib/ai/sql_assistant.dart:253`).
- **Failure.** A named query (in a metadata file or a `meta_query` row), a chart's SQL, or an action that starts with a `-- …` or `/* … */` comment, or with a parenthesis (`(SELECT … ) UNION (SELECT … )`), or an `INSERT`/`UPDATE`/`DELETE` whose `RETURNING` is preceded by a newline rather than a space, run against a local `.db` or a phone's database: the statement is classified as non-query, the SELECT is executed through `statement.execute` with its rows thrown away, and the caller receives zero columns/rows plus `affectedRows` left over from the previous write. The named-query tab and every chart render "no rows" with no error, so a query that matches thousands of rows looks like it matched none — and the leftover affected count can look like a successful write. Generated SQL (`dml.dart`, the pager, catalogs) always begins with the keyword, so this only bites metadata-authored SQL, which is where authors put comments.
- **Noticed.** 2026-11-02, while auditing the SQLite executor's statement handling against the named-query and chart paths.
- **Confidence.** confirmed for the misclassification; the discarded result set follows from the non-query branch, and `_db.updatedRows` is SQLite's last write count, not this statement's.
- **Why not fixed on the spot.** Audit only; picking between stripping leading comments, asking `sqlite3_stmt_readonly`/`column_count` after prepare, or a full lexer (the repo already has one in `lib/util/sql_parse.dart`) is a design decision.

### Editing a field in the row inspector and then selecting another row writes the edit to the newly selected row

- **Where.** `lib/inspector/property_inspector.dart:251-257` (`_PropertyFieldRowState.didUpdateWidget`) only re-seeds `_initial`/`_pending` when `!_editing`, so an open editor keeps the previous row's value while the widget is rebuilt with the new row; `_commit` (`:297-306`) calls `onSave(widget.policy, out)` with no row identity. The table view then resolves the target row from the live selection: `lib/table/table_tab_view.dart:783-795` (`_saveCellFromInspector`) reads `tab.selectedRowIndex` at save time and builds `GridEditEvent(rowIndex, …)`.
- **Failure.** In a table tab, double-click a cell in the right-side row inspector (row A) to open its editor, type a new value, then click another row (row B) in the grid and press Save or Cmd+Enter — the editor is still open from row A, and the write goes to row B: `_saveCellFromInspector` takes `oldValue` from row B's cell and `CellEditor.updateCell` binds `WHERE <pk> = <row B> AND <col> IS NOT DISTINCT FROM <row B's old value>`, which matches, so the value typed for row A silently overwrites row B's cell. The optimistic-concurrency guard cannot catch it because it is given row B's own values; the only visible hint is the edit box still showing row A's text. The same stale-editor state means switching rows mid-edit shows one row's value while the header/label refers to the other.
- **Noticed.** 2026-11-02, while auditing the row inspector's edit path against the table view's save handler.
- **Confidence.** confirmed (nothing carries the row identity from the field row to `updateCell`, and `didUpdateWidget` deliberately skips the resync while editing).
- **Why not fixed on the spot.** Audit only; the fix (key the field row by row identity, or close the editor when the selected row changes, or pass the original row's PK with the save) changes editor behaviour and needs a decision.

### Run has no in-flight guard, so a second Run clears Stop and both results race onto the grid

- **Where.** `lib/query/query_tab_view.dart:94` starts `_run` with no `if (tab.isLoading) return` check, and `:115-155` sets `widget.tab.isLoading = false` / `cancelToken = null` from whichever invocation finishes first. The Run button is disabled while loading (`:400-410`) but the editor's keyboard shortcut calls the same callback with no guard: `_EditorAndGrid.onRun` is passed straight to `SqlEditor.onRun` (`:416,427,469`), whose Cmd/Ctrl+Enter action invokes it unconditionally.
- **Failure.** Press Cmd+Enter (or Ctrl+Enter) twice on a slow query: two `QueryRunner.runSql` calls start, each with its own `CancelToken`, and both write `widget.tab.cancelToken`. When the first finishes it sets `isLoading = false` and `cancelToken = null`, so the Stop button vanishes and the spinner stops while the second query is still running — there is nothing left to cancel it with. When the second finishes afterwards it replaces `tab.data`, so the grid can end up showing the earlier run's rows while the editor shows the SQL that was edited in between. `QueryTabView` also never resets `tab.selectedRowIndex` after a run (`NamedQueryView` does, `lib/meta/named_query/named_query_view.dart:168`), so the row inspector can point at a row of the previous result set.
- **Noticed.** 2026-11-02, while auditing the query tab's run/cancel flow.
- **Confidence.** confirmed (missing guard and shared `cancelToken`/`isLoading` fields; the ordering of the two completions is what decides the visible result).
- **Why not fixed on the spot.** Audit only; whether a second Run should be ignored, cancel the first, or queue is a behaviour decision.

### An action that filters by `@me_principal` silently binds NULL, so it matches nothing (or writes NULL) instead of saying it cannot run

- **Where.** `lib/meta/meta_cache.dart:82-86` (`MetaSnapshot.mePrincipal`) returns `user:<claimed email>` only when a claimed identity is set, and never the connected login, although `AccessPolicy` resolves `pg:<role>` principals for the same connection (`lib/meta/access_policy.dart:174-199`). `lib/meta/action_binding.dart:101-104` (`bindSql`'s `valueFor`) then calls `put(context.mePrincipal)` and returns null — meaning "satisfied" — unlike `@column`/`@table`/`@schema` (`:87-100`), which hand the name back so it lands in `missing`. The value is threaded in from `lib/meta/ui/meta_menu.dart:76`.
- **Failure.** With no claimed identity in the connection's metadata settings, a metadata action whose SQL is `SELECT * FROM app.item WHERE owner = @me_principal` runs with `me_principal: null`: `BoundSql.isComplete` is true, `MetaActionRunner._bind` (`lib/meta/ui/action_runner.dart:126-150`) only refuses masked values, so no "needs @me_principal" message is shown. Reads come back empty (looks like "you have no rows" instead of "this action needs your identity") and writes store NULL. The same happens on a Postgres connection where the login and its roles are known — `mePrincipal` ignores `identity.postgresRoles`, so the placeholder is NULL even though the policy resolved `pg:<role>` grants for that connection. The claimed email is also passed through unlowercased while `AccessPolicy.resolve` stores `user:` principals lowercased, so `user:Sam@Example.com` never equals a member row written as `user:sam@example.com`.
- **Noticed.** 2026-11-02, while auditing the metadata action binding path.
- **Confidence.** confirmed (the missing-value branch is simply absent for this one placeholder, and `mePrincipal` has no role fallback).
- **Why not fixed on the spot.** Audit only; whether `@me_principal` should fall back to the Postgres login, and whether a NULL should refuse the action, is a product decision.

### On SQLite, any metadata parameter written with a driver type annotation fails to parse (`@x:int8` becomes `:x:int8`)

- **Where.** `lib/db/sqlite_param_translator.dart:169-180` rewrites `@name` to `:name` and then copies the rest of the token through, so `@id:int8` becomes `:id:int8`; the positional path (`:126-138`) rewrites `$N` to `?N` and leaves a following `::type` cast in place. `lib/meta/action_binding.dart:163-181` (`toPositional`) turns `@x:int8` into `$1::int8`, and `:139-148` keeps the annotation when it expands a `@rows_<col>` selection. Every binding call site can reach SQLite: `lib/meta/ui/action_runner.dart:111,167`, `lib/meta/named_query/named_query_view.dart:121`, `lib/meta/charts/chart_data.dart:187`.
- **Failure.** On a local `.db` or a phone's app database, run a metadata action whose SQL uses the driver's own annotation syntax (`@row_id:int8`), the same SQL as an open-table action filter, a row-scoped chart, or a named query with a typed input. SQLite does not allow `:` inside a parameter name and has no `::` cast, so the statement never runs: `sqlite3` 3.45.1 answers `near ":int8": syntax error` for `WHERE id = :id:int8` and `unrecognized token: ":"` for `WHERE id = ?1::int8`. The identical SQL without the annotation works, so the annotation is the trigger; Postgres accepts both forms, which is why metadata authored against Postgres breaks only once the same action or query is used on a SQLite connection.
- **Noticed.** 2026-11-02, while auditing the metadata binding path together with the SQLite placeholder translator.
- **Confidence.** confirmed (both rewritten shapes replayed against SQLite 3.45.1).
- **Why not fixed on the spot.** Audit only; the fix has to decide whether to drop the annotation or to turn it into `CAST(?N AS …)`, and which SQLite type each Postgres type name maps to.

### Picking a date or time through the picker zeroes the seconds of a timestamp cell

- **Where.** `lib/grid/inputs/parts/date_input.dart:98-112` (`_DateInputState._pick`, the `dateAndTime` case) builds the committed value with `DateTime(year, month, day, hour, minute)`, and `:91-97` does the same for a `time` column with `DateTime(0, 1, 1, hour, minute)`; `_format` (`:23-42`) then always writes the seconds field of that DateTime, which is `00`.
- **Failure.** Edit a `timestamp`/`timestamptz` cell holding `2024-05-01 09:30:45` and change only the day in the calendar (or just confirm it): the value stored is `<new day> 09:30:00`, so 45 seconds disappear although the user never edited the time. A `time` cell holding `10:15:30` becomes `10:15:00` the same way. Typing into the text field instead keeps the value, so the loss comes only from the picker, and it is silent — the cell just shows the truncated value afterwards.
- **Noticed.** 2026-11-02, while auditing the grid cell editors.
- **Confidence.** confirmed (no seconds are ever passed to the constructed DateTime, and the formatter prints the seconds of that value).
- **Why not fixed on the spot.** Audit only; the fix also has to decide what the `time` branch should seed from and whether an untouched time should be preserved verbatim.

### “Export schema as DBML…” on a SQLite connection always fails, and the cache tries it on every connect

- **Where.** `lib/catalog/dbml_export.dart:123-138` always runs an `pg_type`/`pg_enum`/`pg_namespace` query (`_loadEnums`) and `:48` writes `database_type: 'PostgreSQL'` regardless of the connection kind. The menu item is unconditional in the File menu (`lib/shell/menu_bar.dart:217-220`), and `lib/connection/registry.dart:357` warms the same generator on every successful connect. Types come straight from `column.typeName` (`:197-202`), which is Postgres-oriented.
- **Failure.** Connect to a local `.db` file or a phone's app database and choose File ▸ Export schema as DBML…: generation stops at the enum query and the snackbar shows the raw `Export failed: no such table: pg_type` instead of a schema. Replayed on `sqlite3` 3.45.1, that query fails with exactly `OperationalError: no such table: pg_type`. Even with the enum step skipped, the header would claim `database_type: 'PostgreSQL'` and SQLite's declared types would be emitted unchanged. The same generator also fails the background warm on every SQLite connect (`registry.dart:357`), so the cache sits in `failed` and the AI schema path silently drops to its naive catalog walk.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (query replayed against SQLite; the menu item and the warm call have no kind check).
- **Why not fixed on the spot.** Audit only; hiding the item per backend vs. emitting SQLite-flavoured DBML is a product decision.

### The Navigator's row filter is Postgres-only SQL, so filtering a SQLite table always errors

- **Where.** `lib/navigator/parts/row_list_column.dart:103` builds `("col")::text ~* $1` for the regex filter, and the AI-inferrer path feeds the same clause (`lib/navigator/parts/row_list_column.dart:565-575`). Nothing branches on dialect; `KeysetPager` passes the string through as `baseWhere` (`lib/query/pager.dart:36-46,83`). The tab is reachable for any connection kind: `lib/shell/menu_bar.dart:103` (Navigator menu item) and `lib/shell/sidebar_table_actions_default.dart:52`, with the clause documented in `lib/navigator/navigator_tab.dart:80`.
- **Failure.** Open the Navigator on a SQLite connection (local file or a phone's app database), type a filter into a row list and pick a column, or press the AI wand. SQLite has no `::type` cast, so the statement dies before it runs — `sqlite3` 3.45.1 answers `OperationalError: unrecognized token: ":"` for `SELECT "id" FROM "t" WHERE "name"::text ~* ?1`, and the row list shows that error instead of rows. The same clause also assumes Postgres regex (`~*`) where SQLite would need `CAST(col AS TEXT) LIKE …` or a `regexp()` function. Sorting and paging in the same pager are dialect-neutral, so only the filter is broken.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (SQL replayed against `sqlite3` 3.45.1; the single unfiltered path is the only thing that works on SQLite today).
- **Why not fixed on the spot.** Audit only; a fix needs a per-dialect clause, which is a code change and a test.

### An interrupted project-file write silently empties the app, and the next save overwrites the only copy

- **Where.** `lib/project/project_store_io.dart:31-39`: `_writeNow` truncates and rewrites `default.dbscopeproj` in place with no temp file and no rename. `load()` at `:50-64` catches any decode error and keeps an empty `ProjectDocument`, with a comment saying "the old broken file stays on disk for forensics". `_mutate` at `:70-93` re-reads the file, swallows the same decode error, applies the change to the empty document and writes it back.
- **Failure.** Quit the app or lose power while a save is in flight (every profile, saved query, saved AI query and AI setting writes this one file) and the file ends up truncated. On the next launch the app starts with no connections and no saved queries — expected from the comment — but the first mutation (adding a connection, saving a query, changing an AI setting) re-reads the broken file, keeps the empty document, and writes it over the file, so the recoverable original is gone too. Writing to `…tmp` and renaming, plus refusing to overwrite a file that failed to parse, is the fix.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed by code reading (the write is in place, the failure path keeps an empty document, and the next mutation rewrites the same path); the trigger is a crash or disk-full during a save.
- **Why not fixed on the spot.** Audit only.

### Two windows saving different things at once drop one of them: the project document has no cross-isolate lock

- **Where.** `lib/project/project_store_io.dart:32` (`_writeQueue` is a per-isolate field) and `:70-93` (`_mutate` reads the file, applies the change, writes it back). The class comment at `:20-23` claims cross-isolate writes "are handled by re-reading the file inside each mutation"; re-reading only narrows the window, it does not close it.
- **Failure.** The host window and a subwindow each have their own `ProjectStore` singleton in their own isolate. Save a query in one while the other saves a query for a different connection, or saves AI settings, and both read the same document, each adds its slice, and the second write wins: the first window's change is gone with no error (both calls succeed). It also runs the other way round for profiles: `setProfiles` from one window clobbers a query saved by the other. A file lock, a single writer isolate, or an atomic read-modify-write with a lock file fixes it.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (deterministic when the two writes overlap; needs two windows to observe).
- **Why not fixed on the spot.** Audit only.

### Editing any cell on an on-device phone running Android 13 or older fails: `IS NOT DISTINCT FROM` needs SQLite 3.39

- **Where.** `lib/db/dml.dart:44` (`UPDATE … WHERE <pk> = $n AND <col> IS NOT DISTINCT FROM $m`), the SQL every cell edit goes through (`lib/table/table_tab_view.dart:457`, `lib/navigator/parts/row_detail_column.dart:106`). The desktop/local SQLite path uses the bundled `sqlite3` FFI (3.45 here, which accepts the syntax), but the phone path (`packages/dbscope_sqflite_plugin/lib/src/executor.dart`) runs the same statement on the device's own SQLite through `sqflite`.
- **Failure.** Edit a cell in a database inside an app on a connected phone whose Android SQLite predates 3.39 (`IS [NOT] DISTINCT FROM` was added in SQLite 3.39.0, 2022-06-25; Android 13 and earlier ship older SQLite — 3.32 on Android 13). The statement fails with a syntax error near `DISTINCT`, so every cell edit and every PK-guarded update on that backend errors while the same edit works on a desktop SQLite file. Neither `README.md` nor `docs/architecture.md` states a minimum SQLite version for the device backend, and `test/dml_test.dart` only pins the Postgres spelling. SQLite's `IS` operator (`col IS $m`) has the same NULL-safe semantics and works on every version.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (the SQL is confirmed and the syntax limit is documented; whether a given phone is older than 3.39 depends on its Android version).
- **Why not fixed on the spot.** Audit only; choosing between a version floor and a per-backend predicate is a design decision.

### Query history is read-modify-written to one fixed temp file, so two windows finishing queries lose entries

- **Where.** `lib/query/history_store_io.dart:31-45`: `appendHistory` loads the whole file, inserts, writes `history_<connectionId>.json.tmp`, then renames. The temp name is fixed per connection, and the caller is per window (`lib/query/query_tab_view.dart:138`), so every window runs this against the same paths.
- **Failure.** Run a query in the host window and one in a subwindow (or two windows) that finish close together. Both read the same old list, both write the same `.tmp` path, and the second `rename` either moves the second writer's file over the first (one query silently missing from history) or throws `FileSystemException: Cannot rename file … no such file` because the other window already renamed it — that throw is swallowed as a debug print at `lib/query/query_tab_view.dart:145`, so the user never learns the entry was dropped. A per-write unique temp name plus an append/merge step (or a single writer) fixes it.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (deterministic given overlapping writes; needs two windows to observe).
- **Why not fixed on the spot.** Audit only.

### `.db` export deletes the chosen file before it can fail, so exporting over an existing database destroys it

- **Where.** `lib/grid/export_io.dart:84-87` (delete the existing file at the save location), then `:99` (`CREATE TABLE` from the result columns); the file is only replaced by whatever the export manages to write afterwards.
- **Failure.** Export a query result to a `.db` path that already holds a database (the save dialog offers an existing file and confirms the overwrite), and let the export fail. Any failure after the delete leaves a 0-byte or half-written file: the user's previous database is gone and the new one was never produced. The realistic trigger is a duplicate column name — Postgres allows `SELECT a.id, b.id, …`, the grid keeps both columns and `CREATE TABLE "export" ("id" INTEGER, "id" TEXT)` fails with `duplicate column name: id` (reproduced against sqlite3: the statement fails and the file left behind is 0 bytes). A disk-full or permission error at the same point does the same. Writing to a temp file and renaming over the target would make this safe.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (reproduced the `CREATE TABLE` failure; the delete-before-write order is plain code).
- **Why not fixed on the spot.** Audit only; the fix needs a temp-file/rename path in `exportSqlite`.

### `copy_table` holds its target transaction on the shared connection, so every other query on that profile fails while it runs

- **Where.** `lib/server/jobs/copy_table_job.dart:96` (`obtain(targetId)` — the shared executor) and `:167` (`target.runTx` for the whole copy); only the source got a dedicated connection (`:89`). `lib/db/postgres_executor.dart:12` owns a single `pg.Connection`, and `lib/server/services/connection_service.dart:79-81` states the consequence: on the shared connection a long transaction "would make every other server-side query on it throw (the driver refuses queries while a transaction is open)".
- **Failure.** Start a copy job into a database the user is also browsing. The source is safe, but the target transaction stays open on the shared write connection for the entire copy (including the `TRUNCATE` in truncate mode), so every query the user runs against that profile — a table tab refresh, a saved query, a metadata read — throws until the job finishes. Two copy jobs sharing a target profile fail against each other the same way. The job header (`:15-20`) describes exactly this hazard and then applies the mitigation to one end only.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (the code is clear; the failure depends on how `package:postgres` serialises a second query on a connection inside `runTx`, which the project's own comment already answers).
- **Why not fixed on the spot.** Audit only; the fix is to open a dedicated connection for the target too.

### The web build's `.db` export button does nothing at all

- **Where.** `lib/grid/export_web.dart:52-57` (`exportSqlite` returns `null` without doing anything), the button at `lib/query/query_tab_view.dart:347-353` (rendered unconditionally), and `lib/query/query_tab_view.dart:271-272` (a toast only when the result is non-null).
- **Failure.** On the web build — which is supported and reaches Postgres through `packages/dbscope_pg_proxy` — open a query with results and press `.db`. Nothing is written, no error is shown and no message appears, because the web stub returns `null` and `_export` treats `null` as "the user cancelled". CSV and JSON copy to the clipboard and report it, so the button looks broken rather than unavailable. The button should be hidden (or explain why) on web, and a `null` result that is not a cancel should say so.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (stub body plus the null handling).
- **Why not fixed on the spot.** Audit only.

### CSV export leaves a bare `\r` unquoted, splitting the row into two records

- **Where.** `lib/grid/export_io.dart:174-179` and the identical web copy at `lib/grid/export_web.dart:65-70`; `_csvEscape` quotes only when the text contains `,`, `"` or `\n`.
- **Failure.** Export a text value that contains a carriage return without a line feed (old Mac line endings, or a value pasted from a legacy file). The field is written unquoted, and RFC 4180 readers treat a lone CR as a record terminator, so one row becomes two: the rest of the value lands in a new record and every column after it shifts. Reproduced with Python's `csv` reader on the exact escaping rule: the written line `1,a\rb` parses as `['1', 'a']` followed by `['b']`, i.e. an extra row with one column. Adding `\r` to the quote test (and normalising CRLF) fixes it.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (reproduced the parse of the generated CSV).
- **Why not fixed on the spot.** Audit only.

### `TableTabView._readOnly()` is hardcoded `false`, so a read-only connection is editable in the grid and the delete/insert guards can never fire

- **Where.** `lib/table/table_tab_view.dart:151` (`_TableTabViewState._readOnly`); used at `lib/table/table_tab_view.dart:178` (`connectionReadOnly:`), `:407`, `:526`, `:612` (the "This connection is read-only." toasts) and `:958` (passed to the grid).
- **Failure.** Open a profile whose `readOnly` is on (or flip it on mid-session). The grid is still handed `readOnly: false`, `buildEditPolicies(connectionReadOnly: false)` (`lib/db/edit_policies.dart:95`) leaves every column editable, and the edit/delete/insert paths all pass their `_readOnly()` check, so the three "This connection is read-only." toasts are unreachable code. On Postgres the write then fails server-side with a 25006 error toast (`lib/util/pg_errors.dart:81`) instead of the action being disabled; on a backend that cannot set session read-only (no `sessionReadOnly` capability) nothing stops the write at all. Every other view reads the real state from `ConnectionRegistry.instance.isReadOnlyFor(...)` (`lib/meta/ui/meta_menu.dart:258`, `lib/meta/ui/meta_admin.dart:502`).
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (the function body is the constant `false`).
- **Why not fixed on the spot.** Audit only; no code changes in this task.

### Keyset pagination silently stops when the sort column is NULL at a page boundary

- **Where.** `lib/query/pager.dart:152`–`:165` (cursor built as `(<sort>, <pk...>) < / > ($n, ...)`), taken from `_lastSortVals`/`_lastPrimaryKeyValues` at `lib/query/pager.dart:119-121`; the sort column comes from `lib/query/runner.dart:167` and any nullable column is sortable (`lib/table/table_tab_view.dart:369`).
- **Failure.** Sort a table by a nullable column whose page boundary lands on a NULL (DESC puts NULLs first, so page 1 usually ends there; ASC puts them last). The next request is `WHERE (col, pk) > (NULL, …)` (or `<`), which evaluates to NULL for every row, so page 2 comes back empty and `_done` is set — the table looks like it ends after the first 500 rows. Verified against SQLite: `SELECT … WHERE (sortval,id) < (NULL,2) ORDER BY sortval DESC, id DESC` returns `[]` for a table that still has rows, while the same query with a non-NULL cursor returns them. Nothing in the pager or the catalog emits `NULLS FIRST/LAST` or compares `IS NOT DISTINCT FROM` next to `>`/`<` (grep finds no `NULLS` handling).
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (reproduced the generated cursor against SQLite; Postgres row comparison treats NULL the same way).
- **Why not fixed on the spot.** Audit only; the fix needs a cursor design decision (`NULLS FIRST/LAST` plus a NULL-aware predicate, or refusing to sort on nullable columns).

### Soft delete writes `now()`, which SQLite does not have, so it fails on local and on-device SQLite

- **Where.** `lib/db/dml.dart:88` (`CellEditor.softDeleteRow`, `SET $column = now()`), reached from `lib/table/table_tab_view.dart:576` and `lib/navigator/parts/row_detail_column.dart:181`; the same file's comment at `lib/db/dml.dart:35` says `CURRENT_TIMESTAMP` was chosen for `updateCell` precisely because it works on Postgres *and* SQLite.
- **Failure.** Give a SQLite profile (local `.db` or the USB on-device kind) a soft-delete column — profile override `softDeleteColumn` or metadata `policy.softDelete` — and delete a row. `UPDATE "t" SET "deleted_at" = now() WHERE …` fails with `SqliteException: no such function: now` (reproduced against sqlite3: `now()` fails, `CURRENT_TIMESTAMP` works), so every soft delete on SQLite errors out while the confirmation dialog (`lib/table/table_tab_view.dart:561`) promises an `UPDATE … now()`. Nothing gates soft delete by backend: `writeRulesFor` (`lib/db/write_rules.dart:85`) returns the column for any kind.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** confirmed (SQL-level; the app path is soft-delete on a SQLite profile).
- **Why not fixed on the spot.** Audit only.

### Every window numbers its RPC envelopes from `c1`, but `Server` keeps subscription state in one map keyed by that id

- **Where.** `lib/server/server.dart:24` (`_subs`, commented as "scoped to the replier" but keyed only by `env.id`), `:46` (`unsub` cancels by id), `:124` (assign by id); ids minted per client by `lib/rpc/backend_client.dart:22` (`'c${++_seq}'`); every window builds its own client (`lib/main.dart:115` for a subwindow, the host's `localClient`) and all envelopes land on the one host `Server` (`lib/main.dart:135`).
- **Failure.** The host and each subwindow both start at `c1` and both subscribe to the same things in the same order (`ConnectionRegistry.bind` → `profile.changed`, then `meta.*`), so their ids collide by construction. A window that closes one of its streams sends `unsub` with, say, `c4`; the server cancels whichever subscription was stored under `c4`, normally the *other* window's live stream, which then goes silent (job progress frozen, profile/meta updates missing) while the first window's own stream leaks. `end`/`err` (`lib/server/server.dart:117`, `:121`) also delete another window's map entry. Two windows each opening a job tab is enough to hit it (`lib/jobs/job_tab_view.dart:28-29`).
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (code-level collision is certain; needs two windows in the same session to observe).
- **Why not fixed on the spot.** Audit only; the fix (namespacing subscription ids per transport/replier) touches the RPC layer and needs its own review.

### A job that finishes before its tab subscribes never reports `finished`, leaving the tab "running" forever

- **Where.** `lib/server/services/job_service.dart:70-71` (job started with `unawaited(_run(...))` before the id is returned) and `:91` (`job.finished:<id>` published as soon as it ends); `lib/jobs/job_tab_view.dart:28-29` subscribes to `job.progress:`/`job.finished:` only after the tab is built, and never asks `job.get` for current state (`lib/rpc/services/job_client.dart:32` is only used elsewhere).
- **Failure.** Submit a fast job (a copy of a small table, or one that fails immediately). `job.finished:<id>` is published before the tab's two `bus.subscribe` envelopes reach the server, so the event has no subscriber. The tab then shows the job as running indefinitely: `widget.tab.finished` is only set from that event (`lib/jobs/job_tab_view.dart:55-67`), so the Cancel button and the "running" status stay forever.
- **Noticed.** 2026-11-02, while auditing the repo for bugs.
- **Confidence.** likely (race; no initial `job.get` in the tab to recover).
- **Why not fixed on the spot.** Audit only.

### `scripts/add_changelog_line.sh` can't add any line: `CHANGELOG.md` has no `---` line

- **Where.** `CHANGELOG.md` header; the check is in `scripts/add_changelog_line.sh` (the awk `END` block)
- **Failure.** `bash scripts/add_changelog_line.sh "<line>"` exits 1 with `CHANGELOG.md needs a --- line under its header`, so no change since then has a changelog line. The SEO landing-page change of 2026-11-02 is missing one: "Landing page: canonical URL, fuller social tags, SoftwareApplication and FAQPage structured data, a visible FAQ, sitemap.xml and llms.txt, checked on every Pages deploy by scripts/check_site_seo.sh". Also missing (2026-11-03): "Fix inline cell editing in table grids: the editor now takes keyboard focus on double-click / Enter, stays open while you type (it used to save and close after one character), lets arrow keys and Cmd-A work inside the field, and saves on Enter, Tab or clicking another cell (Esc discards)".
- **Noticed.** 2026-11-02, finishing `/find-seo-aeo-improvements`.
- **Confidence.** confirmed (script output)
- **Why not fixed on the spot.** Agents are blocked from reading `CHANGELOG.md`; a person needs to add the `---` line under its header, then re-run the script with the line above.

### Query result headers show `Type(oid:2950)` instead of the Postgres type name

- **Where.** `lib/db/postgres_executor.dart:54` (`PostgresExecutor.execute`, `typeName: column.type.toString().split('.').last`)
- **Failure.** Run any query in a Query tab against Postgres: the column headers read `Type(oid:2950)` for a `uuid` column and `Type(oid:25)` for `text`, because `pg.Type.toString()` prints the oid, not a name. Anything keyed on `DbColumn.typeName` (the typed-cell colours in `lib/grid/typed_value_text.dart`) likely gets no match for query results.
- **Noticed.** 2026-10-30, while cropping screenshots of the AI SQL feature for a social post.
- **Confidence.** likely (seen in the screenshot, not traced through the colour mapping)
- **Why not fixed on the spot.** Outside the task (marketing assets only, no app code changed).

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->

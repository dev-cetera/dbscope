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

### A URL that ends a sentence is launched with the full stop (or comma, or bracket) attached

- **Where.** `_urlPattern` in `lib/grid/typed_value_text.dart` is `RegExp(r'https?://[^\s<>"\)]+')` — everything up to whitespace, `<`, `>`, `"` or `)` — and `_buildSpansWithUrls` turns each match into `_Match(match.start, match.end, match.group(0)!, match.group(0)!)`, using the matched text unchanged as the launch URI.
- **Failure.** A notes or description column holding `See https://example.com/docs/setup.` underlines `https://example.com/docs/setup.` and opens it with the trailing period, which is a different path — the site answers 404 and the user concludes the link is dead. The same happens with a comma (`…/a, then …`), a semicolon, an exclamation mark, a closing `]` or `}`, and a quoted URL (`"https://…"` keeps neither quote because `"` is excluded, but `'…'` single quotes are not). Trailing `)` is the only one handled, because it is excluded outright — which also breaks a legitimate URL whose path contains a parenthesis (Wikipedia links do).
- **Noticed.** 2026-11-03, while reading the URL/email/phone detection in the cell renderer.
- **Confidence.** confirmed (the launch URI is the raw match; no trimming step between the regex and `launchUrl`).
- **Why not fixed on the spot.** Audit only; trimming trailing punctuation is easy, but doing it without breaking real URLs that end in `)`, and without cutting a legitimate trailing `/`, is a small rule that belongs with a test, and the phone matcher next to it explicitly documents which strings it must *not* light up, so the two should be decided together.

### A histogram chart is an arbitrary 10 000-row sample presented as the whole table's distribution

- **Where.** `buildTableChartSql` (`lib/meta/chart_sql.dart`) returns `SELECT $xIdent AS x FROM $from WHERE $xIdent IS NOT NULL LIMIT $kHistogramSampleRows` — `kHistogramSampleRows = 10000`, no `ORDER BY`, no `TABLESAMPLE`, and `_shape` in `lib/meta/charts/chart_data.dart` then bins whatever came back. `lib/meta/charts/chart_view.dart` contains no "sample"/"truncated" wording at all (`rg -i 'sample|truncat'` finds nothing).
- **Failure.** On a table with a million rows the histogram bins the first 10 000 the server happens to return — in practice the oldest rows in heap order — and draws it as the distribution of the table, with no label saying otherwise. A histogram of `orders.total` on a growing table therefore shows the distribution from when the table was small, and a chart of `created_at` buckets can show a range that ends years ago. The number is silently different from what the same chart says on a small table, and nothing in the UI distinguishes "the whole table" from "10 000 rows of it".
- **Noticed.** 2026-11-03, while reading the chart SQL builder.
- **Confidence.** confirmed (constant plus missing clause plus absent indicator are all visible).
- **Why not fixed on the spot.** Audit only; the honest fix is either a random/id-ordered sample (`ORDER BY random() LIMIT …`, which is a full scan on a big table) or drawing a real histogram in SQL (bucket counts server-side), and the chart needs to say which one it did.

### Switching "View as" keeps the old DBML, so tables hidden from that role still reach the AI prompt and the export

- **Where.** `DbmlCache` (`lib/catalog/dbml_cache.dart`) is keyed by `profileId` alone and invalidated only from `lib/connection/registry.dart:134,175,253,511` (connect, profile change, disconnect, profile delete). `MetaCache.viewAs` (`lib/meta/meta_cache.dart:182`) swaps the snapshot's policy via `_withPolicy` and never invalidates the DBML cache, and a metadata reload does not either. Both consumers read that cache: `SqlAssistant.buildSchemaContext` (`lib/ai/sql_assistant.dart`) does `DbmlCache.instance.peek(profileId)` / `get(profileId, conn)`, and the File ▸ Export schema as DBML… flow reads it the same way.
- **Failure.** The cache is warmed at connect under whatever policy applied then (usually unrestricted), so after the owner switches "View as" to a restricted role the schema context sent to the AI provider — and the DBML written by the export — still contains every table and column that `SchemaCatalog.listColumns` now hides, and the same happens after the metadata is reloaded with a tightened grant. The prompt deliberately filters its `ai` notes by visibility (`_metadataNotes` → `visible()`), so the intent is clear; the schema block it is appended to does not follow the same rule, so a viewer who is restricted to one table can ask "what tables exist?" and the answer is the full schema, and an export produced under "View as" is the unrestricted one.
- **Noticed.** 2026-11-03, after confirming `dbml_export.dart` filters the catalog it walks ("tables and columns at access level `none` never reach the DBML") and checking every `invalidate` call site.
- **Confidence.** likely (the invalidation sites are enumerated above; whether some other path re-warms under the new policy was not found, but the warm is fire-and-forget at connect so timing also matters).
- **Why not fixed on the spot.** Audit only; the fix is to invalidate on `viewAs` and on every metadata reload, or to key the cache by `(profileId, viewAsRoleIds)` — the second is more correct because two viewers legitimately need two DBML strings, but it also means the per-connect warm only helps the unrestricted case.

### The generated privilege script cannot take a column privilege away, so a column narrowed to `none` stays readable

- **Where.** `buildEnforcementPlan` in `lib/meta/enforcement_sql.dart`: every table starts with `REVOKE ALL ON $qualified FROM $quotedRole;` and then re-grants per column when not every column is readable (`GRANT SELECT ($columnList) ON $qualified TO …`). In Postgres, column privileges live in `pg_attribute.attacl`, not in the table's `relacl`, and `REVOKE ALL ON <table>` only clears the table-level ACL — the column grants from the previous run of the script survive it.
- **Failure.** A role that was generated with `GRANT SELECT (id, email, phone) ON public.people` and is then narrowed in the metadata so `phone` becomes `none` gets a regenerated script whose only relevant statements are `REVOKE ALL ON public.people` (no effect on the column grant) and `GRANT SELECT (id, email)`. After running it, the role still holds `SELECT (phone)`: the enforcement the plan promises — and the `PrivilegeExpectation(granted: false)` it records for that column — is not what the database ends up with, so a column the metadata hides stays readable to anyone who can talk to Postgres directly. The file's own header says "a column REVOKE does nothing while the role holds table-level SELECT", which is true but not the whole rule: the REVOKE they do emit never reaches column ACLs either.
- **Noticed.** 2026-11-03, while reading the enforcement script generator.
- **Confidence.** likely (the emitted statements are plain; the Postgres ACL semantics were reasoned from `relacl`/`attacl` being separate, not from a live test).
- **Why not fixed on the spot.** Audit only; the fix is to revoke the columns explicitly (`REVOKE SELECT (<all columns>) ON <table> FROM <role>` before granting, or per-column REVOKE for the ones that lost access) — a change to the generated script that also needs its drift check (`PrivilegeExpectation`) to keep matching, since a script that no longer reflects the expectations is what this entry is about.

### A row-scoped chart binds `MaskedValue`s into its SQL parameters instead of refusing, so a masked column silently ruins the chart

- **Where.** `runChart`'s `ChartSqlSource` branch in `lib/meta/charts/chart_data.dart` does `final bound = bindSql(sql, row); if (!bound.isComplete) throw …` and then hands `bound.named` straight to `executeReadOnly`. `bindSql` does not filter or reject masked values — the action path has a separate guard for exactly this (`MetaActionRunner._bind`, `lib/meta/ui/action_runner.dart`, `if (bound.named.values.any((value) => value is MaskedValue))` → "uses a value that is masked for you, so it cannot run"), and the chart path has no equivalent check.
- **Failure.** A metadata row chart whose SQL writes `… WHERE status = @row_status` on a table where `status` is masked for the viewer binds the `MaskedValue` sentinel as a parameter: on Postgres the driver has no encoder for it and the chart fails with an opaque codec/encoding error, on SQLite the sentinel's text is bound and the chart quietly returns zero rows — a blank chart that looks like "no data" rather than "you may not plot this". The file's header claims "All access checks happen here, before any SQL runs", which holds for table and named-query charts but not for this branch.
- **Noticed.** 2026-11-03, while comparing the chart runner with the action runner's bind guard.
- **Confidence.** likely (no refusal in the chart path is certain; which of the two failures appears depends on the backend's parameter encoder).
- **Why not fixed on the spot.** Audit only; the right refusal message belongs next to the other chart errors, and deciding whether a masked `@row_` value should disable the chart or let the viewer see it with the column dropped is a product call.

### Stop cannot stop a running Postgres query: the cancel token is never delivered and `cancelByClose` is read by nobody

- **Where.** `PostgresExecutor.execute` (`lib/db/postgres_executor.dart:41-56`) contains an `if (cancelToken?.isCancelled ?? false) { … }` block whose body is only a comment — the token is never passed to `package:postgres`, never used to close the socket, and never turned into a cancellation. The capability that is supposed to make this work, `DbCapabilities.cancelByClose` (`lib/db/executor.dart:58-78`), has no reader anywhere in `lib/` (`rg 'cancelByClose' lib/` returns only its declaration, the `postgres` preset and a comment in `sqlite_executor.dart`). The query tab only creates the token and hands it to the runner (`lib/query/query_tab_view.dart:115-126`); the runner checks it after `conn.execute` completes (`lib/query/runner.dart`, `if (cancelToken?.isCancelled ?? false) throw const _CancelledException()`).
- **Failure.** Pressing Stop on a long `SELECT` against a Postgres (or Cloud SQL / pg-proxy) profile appears to work — the tab stops waiting and shows "cancelled" — while the statement keeps running on the server, holding its locks, MVCC snapshot and connection slot until it finishes. On a `SELECT` that takes minutes or a query that blocks DDL, the user has no way to end it from the app: pressing Stop again only discards another result, and the `cancelByClose` flag that would have closed the socket is dead code. On SQLite the token is likewise checked only after the synchronous FFI call returns.
- **Noticed.** 2026-11-03, while checking whether the query runner's limit entry could lean on Stop.
- **Confidence.** confirmed that nothing consumes `cancelByClose` and that the executor ignores the token; the UI symptom ("appears cancelled, server keeps running") follows from that.
- **Why not fixed on the spot.** Audit only; a real fix means choosing per backend — closing the socket for `package:postgres` (which kills every other query on that connection and needs the connection re-established) versus `pg_cancel_backend` on a second connection, which needs the backend PID and a way to dial a second session, including through the proxy and phone transports.

### Hiding the tenant or soft-delete column from a viewer silently drops the filter, so they see every tenant and every deleted row

- **Where.** `_composeBaseWhere` in `lib/query/runner.dart` (the `tenant != null && columnNames.contains(tenant.column)` and `softDeleteColumn != null && columnNames.contains(softDeleteColumn)` guards) decides whether to add the tenant clause and the `<col> IS NULL` clause from `columnNames`, which `TableLoader.loadTable` builds from `catalog.listColumns(...)` — and `SchemaCatalog.listColumns` **drops columns at access level `none`** (`lib/catalog/schema_catalog.dart`, the `if (!primaryKeyNames.contains(column.name)) continue;` branch). The same `columnNames` guard also decides `tenantFilterApplied` and `effectiveSoftDeleteColumn`, so the UI reports the filter as absent rather than skipped.
- **Failure.** A profile with a tenant filter on `account_id`, plus metadata that hides `account_id` (access level `none`, a normal thing: the column is noise for most viewers), makes the filter vanish for those viewers: the table opens showing **every account's rows**, with no badge and no warning, because `tenantFilterApplied` is false. The soft-delete case is the same: hiding `deleted_at` makes `showDeleted: false` skip the `IS NULL` clause, so deleted rows reappear in the grid and the "Show deleted" toggle does nothing either way. In both cases the failure is the wrong direction — the more the column is restricted, the fewer restrictions apply.
- **Noticed.** 2026-11-03, while reading how the table loader composes its base WHERE from the access-filtered catalog.
- **Confidence.** confirmed (the guards read the filtered list, and `listColumns` provably drops `none` columns; only whether real metadata combines a tenant filter with a hidden tenant column was not observed).
- **Why not fixed on the spot.** Audit only; the fix needs a privilege-independent source for these two columns (the unfiltered catalog, or the profile/metadata names checked against `_listColumnsRaw`) and a decision on what to do when the filter column is hidden but the filter must still apply — filtering a column the viewer cannot see is fine in SQL, but the "filtered by tenant" badge then leaks the column's existence.

### A query's result limit is applied after the driver has already read every row, so a large result still exhausts memory

- **Where.** `QueryRunner.runSql` in `lib/query/runner.dart`: `conn.execute(...)` returns the whole `DbResult` (all rows decoded into `List<Object?>` by `PostgresExecutor.execute`), and only afterwards the loop `for (final row in result.rows) { if (rows.length >= maxRows) { truncated = true; break; } … }` cuts the grid down to `maxRows = 10000`.
- **Failure.** Running `SELECT * FROM events` on a table with a few million wide rows still materialises every row across the socket, through the driver's decoding, and into a Dart list before the limit applies — so the app can stall for minutes or die of memory exhaustion on a query the UI claims it truncates at 10 000 rows, and Stop cannot help because the flag is only checked after the future completes (`postgres_executor.execute` has an empty `if (cancelToken?.isCancelled ?? false)` block). A `LIMIT 10001` sent to the server, or a streaming/cursored fetch, would make the limit real.
- **Noticed.** 2026-11-03, while auditing the query runner's result handling.
- **Confidence.** confirmed mechanism (no LIMIT, no cursor, limit applied to the in-memory rows); whether a given machine dies or merely stalls depends on the result size.
- **Why not fixed on the spot.** Audit only; pushing the limit into SQL changes the runner's contract (a user-written `LIMIT` must win, and `SET`/`EXPLAIN` results must not be wrapped), and the streaming alternative needs executor-level changes across all four backends.

### The CHECK-violation toast can quote a different table's constraint, because the lookup matches the name alone

- **Where.** `lib/catalog/schema_catalog.dart:665-680` (`SchemaCatalog.lookupCheckDefinition`) runs `SELECT pg_get_constraintdef(con.oid, true) … WHERE con.contype = 'c' AND con.conname = @name LIMIT 1` — no schema or table, and `LIMIT 1` picks whichever row the planner returns first. Called from `lib/table/table_tab_view.dart:505` to enrich a 23514 error.
- **Failure.** Postgres only requires constraint names to be unique per table (`orders_quantity_check`, `items_quantity_check` are common), so a database with two tables that share a check name (or the same generated name after a rename/restore) makes an edit on table A fail with "23514 check_violation" and then shows the definition of table B's check as if it were the rule that fired. The user reads the wrong rule and changes the wrong column. On SQLite the lookup returns null and no definition is shown at all.
- **Noticed.** 2026-11-03, while auditing the catalog's Postgres queries.
- **Confidence.** confirmed (name-only predicate, `LIMIT 1`, no ordering).
- **Why not fixed on the spot.** Audit only; the caller knows the failing table (`_saveCell`/`_delete` path in `table_tab_view.dart`), so the fix is to pass `schema` and `table` through and filter on `conrelid`, which changes the method's signature and its one call site.

### On SQLite, every column reports `isIdentity: false`, so no autoincrement key is ever recognised

- **Where.** `lib/catalog/schema_catalog.dart:372` (`_sqliteListColumns` hardcodes `isIdentity: false`) directly under a comment that says "SQLite's INTEGER PRIMARY KEY is the rowid alias (identity-ish); we surface that as identity for callers that gate INSERT-time value entry." Consumers that trust the flag: `lib/db/edit_policies.dart:103` (marks identity columns read-only), `lib/catalog/dbml_export.dart:140` (`if (column.isIdentity) attributes.add('increment')`) and `lib/inspector/property_inspector.dart:94`.
- **Failure.** "Export schema as DBML" on a local file or a phone's app database never emits `increment` for `INTEGER PRIMARY KEY` columns, so the exported DBML recreates the table without its autoincrement and an import into another tool loses the key generation. In the app, `EditPolicy.isIdentity` is false for the same column, so the insert dialog offers the generated key as an ordinary editable column and a blank value is sent as `''` (an `INTEGER PRIMARY KEY` rejects it, `TEXT` stores the empty string) instead of being omitted. The comment asserts the opposite behaviour, so the intended branch can never run.
- **Noticed.** 2026-11-03, while reading the SQLite catalog builder.
- **Confidence.** confirmed for the flag; the export and insert consequences follow directly from the two consumers cited.
- **Why not fixed on the spot.** Audit only; deciding what counts as identity on SQLite (`INTEGER PRIMARY KEY` only, or also `AUTOINCREMENT`, and not `WITHOUT ROWID` tables) and whether a composite PK that includes it can be identity is a schema-model decision, and the flag also feeds "read-only" in `edit_policies`.

### `indexedColumns` reports every column of a covering index as indexed, including its `INCLUDE` payload

- **Where.** `SchemaCatalog.indexedColumns` (the Postgres branch in `lib/catalog/schema_catalog.dart`) selects `DISTINCT a.attname … a.attnum = ANY(i.indkey)`. `pg_index.indkey` holds all `indnatts` entries — the key columns *and* the `INCLUDE` columns added in Postgres 11 — and the query never looks at `indnkeyatts`, nor at `indpred` for partial indexes, nor at `indexprs`.
- **Failure.** `CREATE INDEX ON orders (created_at) INCLUDE (status)` makes `status` show as indexed in the grid's column badge and in the table's index hints, although a predicate on `status` alone cannot use that index. The same is true of a partial index (`… WHERE deleted_at IS NULL`), which cannot serve a query without the predicate. The badge is a hint, so the damage is a user trusting a plan that the database will not use — and, when the badge is used to decide whether a filter is cheap, guessing wrong about a slow query.
- **Noticed.** 2026-11-03, while auditing the catalog's index query.
- **Confidence.** likely (the query text is plain; only the exact consumers of `ColumnInfo`-level index flags were not traced end to end).
- **Why not fixed on the spot.** Audit only; the honest fix needs three states (usable key column, `INCLUDE` payload, partial/expression index) rather than one set of names, which changes `TableSchema.indexedColumns` and every consumer.

### A metadata `when` condition with a null value is dropped, so the action shows on every row

- **Where.** `lib/meta/meta_models.dart:846-854` (`ActionSpec.fromRow`): the `when` map is built from `value is List` and `else if (value != null)`, so a key whose value is YAML `null`/`~` is stored nowhere and leaves no `MetaProblem`. `whenHolds` in `lib/meta/action_binding.dart` can then only iterate the conditions that survived.
- **Failure.** A metadata author writes `when: {row.deleted_at: null}` ("only offer Restore on rows that are deleted", or "only offer Archive on live rows"). Parsing drops the condition silently, `ActionSpec.when` is empty, `whenHolds` returns true for every row, and the action is offered on all of them — including the rows where its SQL does the wrong thing. Nothing in the metadata admin view reports the dropped condition, so the only symptom is a button that appears where it should not. A single-element list (`[null]`) hits the same gap because `when` only accepts `List<String>` and `null.toString()` never reaches the list branch.
- **Noticed.** 2026-11-03, while auditing how action conditions are parsed and evaluated.
- **Confidence.** confirmed for the parse (both branches skip null); the visible failure depends on someone writing a null condition, which the "only when" use case invites.
- **Why not fixed on the spot.** Audit only; supporting null means deciding the model (`List<String?>` vs a separate `isNull` list) and whether `whenHolds` should compare a null cell to an empty string, so it is a metadata-format decision, not a one-line guard.

### Two Navigator row-list loads can finish out of order, so the grid shows rows for a filter the user has already changed

- **Where.** `lib/navigator/parts/row_list_column.dart` (`RowListColumn._load`): every call clears `step.data`, awaits the catalog reads and `pager.fetchNext()`, then assigns `step.columns`, `step.data` and `step.pager` with no generation counter, request id or cancel token. Callers that can overlap: the 300 ms filter debounce, `onSubmitted`, the Reload button, `_onFilterColumnChanged` and `_runAiInfer` (which awaits `_load` after `setState`).
- **Failure.** Type `sm` then `smith` with a pause that lets the first debounce fire: two loads are in flight. The first (slower, wider table read) can land after the second, overwriting `step.data` and `step.pager` with rows for `sm` while the filter box and `step.filterPattern` say `smith`. Further scrolling pages the stale pager, so "Load more" continues the wrong query, and clicking a row opens a detail column for a row that is not on screen.
- **Noticed.** 2026-11-03, while auditing the navigator's filter and paging path.
- **Confidence.** likely (no guard exists in `_load`; whether the older request lands last depends on timing, but nothing prevents it).
- **Why not fixed on the spot.** Audit only; the fix is a monotonically increasing load token on `RowListStep` checked after every await (or passing the existing `CancelToken` into the pager), which touches the step model and its tests.

### An action's `roles:` restriction is ignored on a connection with no access control, so an owner-only action runs for everyone

- **Where.** `lib/meta/ui/meta_menu.dart:237` gates the action with `if (action.roles.isNotEmpty && policy.active && !action.roles.any(policy.roleIds.contains))`. `policy.active` is false whenever the metadata has no roles, members or grants (`AccessPolicy.resolve` returns `AccessPolicy.unrestricted` for `!document.hasAccessControl`), which is exactly the metadata that would carry `roles:` on an action without defining any role.
- **Failure.** A metadata file marks a destructive action `roles: [owner]` — `run: exec` with `UPDATE …` or `DELETE …` — while the connection has no rbac block (a plausible intermediate state: actions written first, roles added later, or a sidecar edited by hand). `policy.active` is false, so the roles check is skipped and the button is enabled and runnable by every user of that connection, including its `exec` payload. The same action parsing already records `roles` (`lib/meta/meta_models.dart:878`), so nothing warns that the restriction cannot apply.
- **Noticed.** 2026-11-03, while tracing how `ActionSpec.roles` is enforced at run time.
- **Confidence.** likely (the condition is plain in the code; whether the run path re-checks `roles` was not traced, but the enablement decision is the one documented here).
- **Why not fixed on the spot.** Audit only; deciding between "hide the action", "treat an active-less `roles:` as a metadata problem" or "require rbac for role-scoped actions" is a product decision, and each changes which existing metadata files keep their buttons.

### Editing a `numeric` cell rounds the value through a double and saves the wrong number

- **Where.** `lib/db/dml.dart:172` (`CellEditor.parseValue`, case `PgType.numeric`)
- **Failure.** `numeric` is decoded as an exact `String`, but an edit parses it with `num.parse`, so `12345678901234567890.1234567891` typed into a `numeric(40,10)` cell is stored as `12345678901234567000.0000000000`. Money and other exact decimals with more than about 15 significant digits are silently changed. `insertRow` goes through the same function, so new rows lose precision too.
- **Noticed.** 2026-11-05, while sweeping for bugs (live probe against Postgres 16).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### Editing an `interval` or `time` cell always fails with "Could not infer type"

- **Where.** `lib/db/dml.dart:33` (`CellEditor.updateCell`, the old-value guard parameter)
- **Failure.** The driver decodes these columns to `Interval` and `Time` objects. They are bound untyped as the optimistic-concurrency old value, and `package:postgres` refuses them: `Could not infer type of value '1 days 7200000000 microseconds'` and `... 'Time(10:11:12.000)'`. Every edit of such a column errors out.
- **Noticed.** 2026-11-05, while sweeping for bugs (live probe against Postgres 16).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### Editing a `bytea` cell always reports "Value changed since you loaded it"

- **Where.** `lib/db/dml.dart:33` (`CellEditor.updateCell`, the old-value guard)
- **Failure.** The old value is the decoded `Uint8List`. Bound untyped, it never matches the stored bytes, so the UPDATE affects 0 rows, the user gets the conflict toast and the edit is thrown away. Reproduced on a row holding `\xdeadbeef`.
- **Noticed.** 2026-11-05, while sweeping for bugs (live probe against Postgres 16).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### `money`, `inet`, `cidr`, `macaddr`, `timetz` and `bit` columns show hex or control characters, and can't be edited

- **Where.** `lib/db/postgres_executor.dart:122` (`PostgresExecutor._decodeValue`); the proxy copy at `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart` (`_decodeUndecodedBytes`)
- **Failure.** These types have no codec, so they arrive as binary `UndecodedBytes`. The decoder assumes the bytes are UTF-8 text, which is only true for text-like types. `12.34::money` shows as `\x00000000000004d2`, `10.0.0.1::inet` as a string of control bytes, `'10:00+02'::timetz` as `\x0000000861c46800ffffe3e0`. Editing then sends that text back as the old value: `invalid input syntax for type money`, `invalid byte sequence for encoding "UTF8": 0x00`, `time zone "x0000…" not recognized`.
- **Noticed.** 2026-11-05, while sweeping for bugs (live probe against Postgres 16).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### `interval`, `time`, `bytea` and array cells show Dart's `toString()` instead of Postgres text

- **Where.** `lib/grid/typed_value_text.dart:47` (`TypedValueText.build`)
- **Failure.** Cells render `value.toString()`: `1 days 7200000000 microseconds` for `1 day 02:00:00`, `Time(10:11:12.000)` for `10:11:12`, `[222, 173, 190, 239]` for `\xdeadbeef`, `[1, 2]` for `{1,2}`. Copy (TSV/CSV) uses the same text. An array edit seeded from the `[1, 2]` text is rejected by Postgres with `malformed array literal`.
- **Noticed.** 2026-11-05, while sweeping for bugs (decoded types seen in a live probe; render path read).
- **Confidence.** likely
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### The web proxy fails every query that returns a JSON object

- **Where.** `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart:349` (`_Session._serialize`)
- **Failure.** The map key is `entry.key.toString`, a method tear-off, not `entry.key.toString()`. The result map has function keys, `jsonEncode` throws, and the client gets an error instead of rows for any `json`/`jsonb` column holding an object (or an array containing one). So on the web build a table with a JSON object column can't be opened.
- **Noticed.** 2026-11-05, while sweeping for bugs (read; Dart semantics leave no doubt).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### The web proxy reports every column's type as `Type(oid:N)`

- **Where.** `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart:309` (`_Session._onExecute`)
- **Failure.** `c.type.toString().split('.').last` assumes an enum-style name, but `pg.Type.toString()` in postgres 3.5.11 is `'Type(oid:23)'`. Every query result on the web build carries type names like `Type(oid:23)`, so `pgTypeFromTypeName` sees unknown types: no typed colouring and no type-aware handling in query results. The desktop path uses `pgTypeNameForOid`.
- **Noticed.** 2026-11-05, while sweeping for bugs (read against `postgres-3.5.11/lib/src/types.dart:424`).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### Copy table fails on any table with a generated or `GENERATED ALWAYS` identity column

- **Where.** `lib/server/jobs/copy_table_job.dart:231` (`CopyTableJob.copyRows`)
- **Failure.** Every source column is inserted, including `GENERATED ALWAYS AS (…) STORED` columns, and identity columns without `OVERRIDING SYSTEM VALUE`. Postgres refuses: `428C9: cannot insert a non-DEFAULT value into column "g"`, so the whole job rolls back.
- **Noticed.** 2026-11-05, while sweeping for bugs (live probe against Postgres 16).
- **Confidence.** confirmed (generated); likely (identity ALWAYS)
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### A table with no primary key silently shows only its first 500 rows

- **Where.** `lib/query/pager.dart:76` and `:175` (`KeysetPager`), banner at `lib/table/table_tab_view.dart:1038`
- **Failure.** With no PK the pager returns one `LIMIT 500` page and marks itself done, so the grid never loads more and nothing says the result was cut. The banner only says editing is disabled. A 2 000-row log table, or an SQLite rowid table without a declared PK (common in phone app databases), looks like it has 500 rows.
- **Noticed.** 2026-11-05, while sweeping for bugs (read).
- **Confidence.** confirmed
- **Why not fixed on the spot.** Needs a decision: page by `ctid` / `rowid`, fall back to OFFSET, or at least warn.

### `source ~/file` in the shell env file is never followed

- **Where.** `lib/util/shell_env_io.dart:137` (`ShellEnv._readInclude`)
- **Failure.** `~` is not expanded, so `source ~/.secrets` resolves to `<dir of ~/.zshenv>/~/.secrets`, which doesn't exist, and every key exported there (API keys, `DBSCOPE_CONN_PASSPHRASE`) is missing. This is the most common way people split secrets out of `~/.zshenv`. `$HOME/.secrets` works.
- **Noticed.** 2026-11-05, while sweeping for bugs (probe of `parseShellEnv`).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### Backslashes in a double-quoted shell value are read wrong

- **Where.** `lib/util/shell_env_io.dart:228` (`_parseValue`)
- **Failure.** Escapes are removed before `$` expansion runs, so `export A="ab\$cd"` becomes `ab` (the shell gives `ab$cd`). And any backslash is treated as an escape, so `export B="x\y"` becomes `xy` (the shell keeps `x\y`). A password or key containing `$` or `\` is silently wrong.
- **Noticed.** 2026-11-05, while sweeping for bugs (probe of `parseShellEnv`).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### SQLite `[bracket]` and `` `backtick` `` identifiers confuse the statement splitter

- **Where.** `lib/util/sql_parse.dart:108` (`_skipToken`)
- **Failure.** The SQLite dialect doesn't know these quoting styles. `SELECT [a;b] FROM t` and ``SELECT `a;b` FROM t`` are refused as "Run one statement at a time". The other way round, `SELECT [it's] FROM t; DELETE FROM t` passes the check and `enforceReadOnly` as one statement. SQLite then quietly runs only the first statement and drops the rest, so nothing is deleted, but the user gets no error for the part that didn't run.
- **Noticed.** 2026-11-05, while sweeping for bugs (probe against SQLite via `SqliteExecutor`).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### User SQLite tables whose names start with `sqlite` plus one character are hidden

- **Where.** `lib/catalog/schema_catalog.dart:235` (`_sqliteListTables`)
- **Failure.** `NOT LIKE 'sqlite_%'` treats `_` as "any character", so a user table such as `sqlite3_meta` or `sqlitex` never appears in the sidebar. Only names starting with the literal `sqlite_` are reserved.
- **Noticed.** 2026-11-05, while sweeping for bugs (read).
- **Confidence.** confirmed
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### Opening a pg-proxy connection can hang 15 s when the proxy drops the socket

- **Where.** `packages/dbscope_pg_proxy_plugin/lib/src/executor.dart:223` (`PgProxyExecutor._onDone`)
- **Failure.** If the WebSocket closes before `ready` arrives with no id-less error frame first (proxy crash, network drop, a reverse proxy closing it), `_onDone` fails the pending queries but not `_readyCompleter`. `open()` then waits out the full `_kReadyTimeout` and reports a timeout instead of "connection closed".
- **Noticed.** 2026-11-05, while sweeping for bugs (read).
- **Confidence.** likely
- **Why not fixed on the spot.** The task was to document bugs, not fix them.

### On-device Android pull and cleanup break on paths with spaces

- **Where.** `packages/app_data_explorer/lib/app_data_explorer.dart:199` (`AndroidBackend.pull`), and the `rm -f tmpRemote` in `push`
- **Failure.** `adb exec-out` and `adb shell` join their arguments into one device shell command line, so `remoteRelPath` is split on spaces there. A database at `databases/my app.db` can't be opened. The other commands quote through `_q`, these two don't.
- **Noticed.** 2026-11-05, while sweeping for bugs (read).
- **Confidence.** likely
- **Why not fixed on the spot.** Needs a real Android device to verify.

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->

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

### `money` values are wrong on a database whose currency doesn't use two decimals

- **Where.** `_moneyText` in `packages/dbscope_pg_core/lib/src/pg_value_text.dart`.
- **Failure.** Binary `money` is a count of the smallest unit, and the code always assumes two fractional digits. On a database with `lc_monetary` set to a zero-decimal currency such as `ja_JP`, a stored `1234` shows as `12.34`. A cell edit's concurrency guard then compares against the wrong value.
- **Noticed.** 2026-11-07, while checking value text against a real Postgres 17 (only the two-decimal case was run).
- **Confidence.** likely (from the binary format; not reproduced on a non-two-decimal database).
- **Why not fixed on the spot.** Needs the connection's `lc_monetary` or a `money::text` read, and the decoder has no connection to ask.

### A multi-dimensional array column reads as wrong values on Postgres

- **Where.** The driver's binary array decoder in `package:postgres` 3.5.11, reached from `PostgresExecutor.execute` and the proxy. `PgValueText.decode` only sees its output.
- **Failure.** `SELECT ARRAY[ARRAY[1,2],ARRAY[3,4]]::int4[]` shows `{1,1}` instead of `{{1,2},{3,4}}`, with no error. The grid shows wrong data, and a cell edit's concurrency guard compares against the wrong value, so the edit reports a conflict. One-dimensional arrays are correct.
- **Noticed.** 2026-11-07, while checking value text against a real Postgres 17.
- **Confidence.** confirmed on a live server; not traced further into the driver's decoder.
- **Why not fixed on the spot.** Needs our own array codec registered in the `TypeRegistry` (`PostgresKindPlugin.openConnection` and the proxy's open), for every array oid. That is a separate change.

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->

### Stop can't interrupt a very large write with `RETURNING`

- **Where.** `RowCapMode.readAndDrop` in `packages/dbscope_pg_core/lib/src/pg_session.dart`.
- **Failure.** An `INSERT` or `UPDATE … RETURNING` producing millions of rows floods the socket, and the isolate gets no turn to send a cancel, so the window is sluggish until it ends. Rows past the limit are dropped, so memory stays bounded.
- **Why accepted.** The write has to finish anyway, and this shape is rare in a query tab. A cursor can't carry a write.
- **What would change it.** The driver exposing a row limit on Execute, or reading the socket with backpressure.

### Stop can't interrupt a running SQLite statement

- **Where.** `lib/db/sqlite_executor.dart`, and `packages/dbscope_sqflite_plugin/lib/src/executor.dart`, which wraps it.
- **Failure.** A slow local or on-device SQLite statement runs to the end, and the whole window is unresponsive until it does.
- **Why accepted.** `package:sqlite3` is synchronous FFI on the UI isolate, so nothing can fire a token while a statement runs. Metadata queries are still bounded by the progress-handler deadline (`withStatementTimeout`).
- **What would change it.** Moving SQLite onto its own isolate, which is worth doing if people report large local databases freezing the app.

### A table with neither a primary key nor a sort has no fixed row order between pages

- **Where.** `KeysetPager` in `lib/query/pager.dart`, the no-primary-key OFFSET path.
- **Failure.** Postgres can return an unordered table in a different order on each query (synchronized seq scans, or concurrent writes), so a row can repeat or be missed when scrolling.
- **Why accepted.** Fixing the order means sorting, which turns opening a huge unkeyed table into a full scan per page. Choosing a sort column gives a stable order.
- **What would change it.** A cheap stable order for plain tables, such as a `ctid` range scan, checked against views, partitions and foreign tables.

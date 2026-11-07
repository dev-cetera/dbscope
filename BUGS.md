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

### A no-primary-key table paged by OFFSET can repeat or skip rows between pages

- **Where.** `lib/query/pager.dart` (`KeysetPager`, the no-PK OFFSET path).
- **Failure.** Without a unique ORDER BY, rows that tie on the sort key come back in an unspecified order, so two OFFSET pages can overlap or miss a tied row. Seen when scrolling a big no-PK table sorted by a non-unique column.
- **Noticed.** 2026-11-07, while fixing the 500-row cap on no-PK tables.
- **Confidence.** likely (inherent to OFFSET paging without a unique order; not reproduced).
- **Why not fixed on the spot.** Needs a tiebreaker such as `ctid` / `rowid`, which differs per backend.

### Stop cannot stop a running Postgres query: the cancel token is never delivered and `cancelByClose` is read by nobody

- **Where.** `PostgresExecutor.execute` (`lib/db/postgres_executor.dart:41-56`) contains an `if (cancelToken?.isCancelled ?? false) { … }` block whose body is only a comment — the token is never passed to `package:postgres`, never used to close the socket, and never turned into a cancellation. The capability that is supposed to make this work, `DbCapabilities.cancelByClose` (`lib/db/executor.dart:58-78`), has no reader anywhere in `lib/` (`rg 'cancelByClose' lib/` returns only its declaration, the `postgres` preset and a comment in `sqlite_executor.dart`). The query tab only creates the token and hands it to the runner (`lib/query/query_tab_view.dart:115-126`); the runner checks it after `conn.execute` completes (`lib/query/runner.dart`, `if (cancelToken?.isCancelled ?? false) throw const _CancelledException()`).
- **Failure.** Pressing Stop on a long `SELECT` against a Postgres (or Cloud SQL / pg-proxy) profile appears to work — the tab stops waiting and shows "cancelled" — while the statement keeps running on the server, holding its locks, MVCC snapshot and connection slot until it finishes. On a `SELECT` that takes minutes or a query that blocks DDL, the user has no way to end it from the app: pressing Stop again only discards another result, and the `cancelByClose` flag that would have closed the socket is dead code. On SQLite the token is likewise checked only after the synchronous FFI call returns.
- **Noticed.** 2026-11-03, while checking whether the query runner's limit entry could lean on Stop.
- **Confidence.** confirmed that nothing consumes `cancelByClose` and that the executor ignores the token; the UI symptom ("appears cancelled, server keeps running") follows from that.
- **Why not fixed on the spot.** Audit only; a real fix means choosing per backend — closing the socket for `package:postgres` (which kills every other query on that connection and needs the connection re-established) versus `pg_cancel_backend` on a second connection, which needs the backend PID and a way to dial a second session, including through the proxy and phone transports.

- **Update 2026-11-07.** The footer Cancel button does work, by brute force: `lib/shell/footer.dart` calls `registry.killConnection` (closes the socket) and then reconnects. What is still wrong is every other path that cancels a token (closing or evicting a running tab in `app_state.dart`, the pager and runner, the query tab), which only stops waiting. Closing the socket from inside `PostgresExecutor.execute` when the token fires was tried on paper and rejected: closing a tab would kill the window's shared connection and nothing reconnects it. The driver's own on-demand cancel (`cancelPendingStatement`, a second socket carrying the backend key) is `@internal` in `package:postgres` 3.5.11, so using it means either a dynamic call into private API or giving `PostgresExecutor` a way to dial a second session (a change in `postgres_plugin.dart` / the Cloud SQL and proxy openers). Not verified against a live server.
### A query's result limit is applied after the driver has already read every row, so a large result still exhausts memory

- **Where.** `QueryRunner.runSql` in `lib/query/runner.dart`: `conn.execute(...)` returns the whole `DbResult` (all rows decoded into `List<Object?>` by `PostgresExecutor.execute`), and only afterwards the loop `for (final row in result.rows) { if (rows.length >= maxRows) { truncated = true; break; } … }` cuts the grid down to `maxRows = 10000`.
- **Failure.** Running `SELECT * FROM events` on a table with a few million wide rows still materialises every row across the socket, through the driver's decoding, and into a Dart list before the limit applies — so the app can stall for minutes or die of memory exhaustion on a query the UI claims it truncates at 10 000 rows, and Stop cannot help because the flag is only checked after the future completes (`postgres_executor.execute` has an empty `if (cancelToken?.isCancelled ?? false)` block). A `LIMIT 10001` sent to the server, or a streaming/cursored fetch, would make the limit real.
- **Noticed.** 2026-11-03, while auditing the query runner's result handling.
- **Confidence.** confirmed mechanism (no LIMIT, no cursor, limit applied to the in-memory rows); whether a given machine dies or merely stalls depends on the result size.
- **Why not fixed on the spot.** Audit only; pushing the limit into SQL changes the runner's contract (a user-written `LIMIT` must win, and `SET`/`EXPLAIN` results must not be wrapped), and the streaming alternative needs executor-level changes across all four backends.
- **Update 2026-11-07.** A fix attempt found no honest SQL-only route: wrapping the statement in `SELECT * FROM (...) LIMIT n` breaks on trailing `--` comments, `FOR UPDATE`, `EXPLAIN`/`SET`, and duplicate column names. The real fix is an executor-level row cap (`maxRows` on `DbExecutor.execute`, streaming in `PostgresExecutor`, support in the pg-proxy and sqflite executors and the proxy protocol), which touches files outside the query runner.

### The web proxy still decodes money, inet, interval, bytea and arrays the old way

- **Where.** `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart` (`_decodeUndecodedBytes`, `_serialize`)
- **Failure.** The desktop `PostgresExecutor` now turns `money`, `inet`, `cidr`, `macaddr`, `timetz`, `bit`, `interval`, `time`, `bytea` and array values into Postgres text (`lib/db/postgres_executor.dart`). The proxy has its own copy of the old decoding, so on the web build those columns still show hex or control characters, or Dart's `toString()`, and editing them fails the same way.
- **Noticed.** 2026-11-07, while fixing the desktop decoding.
- **Confidence.** likely (proxy source not re-read after the desktop change).
- **Why not fixed on the spot.** Outside the files this change owned; ideally the proxy shares the decoder instead of keeping a copy.

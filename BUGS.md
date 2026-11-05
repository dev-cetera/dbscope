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

The entries below come from one full bug sweep of `main` at `195d46b` on 2026-11-05, ordered most harmful first. "Confirmed" means a probe ran against Postgres 16 or SQLite in a container, or the failure follows directly from library source that was read; the probes were throwaway tests and are not in the repo.

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

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

### Every SELECT that returns rows on a phone's database pushes the file back to the device

- **Where.** `packages/dbscope_sqflite_plugin/lib/src/executor.dart:209-210` (`_writesToFile` returns true when `result.affectedRows > 0`), fed by `lib/db/sqlite_executor.dart` (`_resultFromSelect` reports `affectedRows: rows.length` for every result set, so a read of 3 rows says 3).
- **Failure.** Open a table (or run any query that returns rows) on a USB-connected phone's app database: the read comes back with `affectedRows > 0`, so `DeviceSqliteExecutor.execute` calls `_pushBack()` and copies the whole `.db` back onto the device and deletes its `-wal`/`-shm` after every page of every grid. Each read costs an adb/devicectl round trip, and each push is the exact operation the dialog warns can corrupt the database or lose the app's own writes if the app is running, though the user only read data.
- **Noticed.** 2026-11-03, while wiring the statement timeout through `DeviceSqliteExecutor`.
- **Confidence.** likely (both lines are plain in the code; not run against a phone).
- **Why not fixed on the spot.** Outside the task (the BUGS.md sweep). The fix is to decide "wrote" from the statement (`!PreparedStatement.isReadOnly`, or `_db.totalChanges` before and after) instead of the row count, which needs the inner executor to expose it.

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->

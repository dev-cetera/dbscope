// Runs SQL that came from schema metadata (named queries, charts, checks,
// query actions) so that it cannot write, whatever it contains.
//
// - Postgres: inside `BEGIN TRANSACTION READ ONLY … COMMIT`. A planted
//   `WITH x AS (DELETE …) SELECT …`, or a call to a volatile function that
//   writes, fails with "cannot execute … in a read-only transaction".
// - Local SQLite: `PRAGMA query_only = ON` around the statement.
// - Backends without transactions (the HTTP pg-proxy, the on-device
//   sqflite snapshot, whose every non-SELECT is pushed to the phone) can't
//   be fenced this way; there, metadata SQL is only as safe as the trust
//   the user gave it.
//
// Two guards keep the fence honest on the window's SHARED connection:
// 1. one fenced statement at a time per executor ([withMetaSession] — the
//    same lock the write-action runner uses), so two charts can't interleave
//    their BEGIN/COMMIT and leave one running outside the fence;
// 2. refuse when a transaction is already open on the connection (a user's
//    `BEGIN` in a Query tab): our BEGIN would be a no-op, our SQL would run
//    read-write, and our COMMIT would commit the user's work.
//
// Other, non-metadata queries (a grid page) can still land inside the
// read-only transaction — harmless for reads; a concurrent edit in that
// instant fails and can be retried.

import 'dart:async';

import '../db/executor.dart';
import '../query/cancel_token.dart';
import 'meta_sources.dart';

/// Whether [executor] can fence metadata SQL into read-only execution.
bool canFenceReadOnly(DbExecutor executor) =>
    executor.capabilities.transactions;

class MetaSessionBusy implements Exception {
  const MetaSessionBusy(this.message);
  final String message;
  @override
  String toString() => message;
}

final Expando<Future<void>> _sessionTail = Expando('metaSession');

/// Runs [body] while holding [executor]'s metadata-session lock, so
/// transaction-scoped metadata work (read-only fences, write actions with
/// `expectRows`) never interleaves on one connection.
Future<T> withMetaSession<T>(
  DbExecutor executor,
  Future<T> Function() body,
) async {
  final previous = _sessionTail[executor] ?? Future<void>.value();
  final done = Completer<void>();
  _sessionTail[executor] = done.future;
  try {
    await previous;
  } catch (_) {
    // A failed predecessor still releases the lock.
  }
  try {
    return await body();
  } finally {
    done.complete();
  }
}

var _probeCounter = 0;

/// Throws [MetaSessionBusy] when the Postgres connection is already inside
/// an explicit transaction block.
///
/// Probe: set a transaction-local setting in one statement and read it back
/// in the next. Outside a block each statement is its own transaction, so
/// the value is gone by the read; inside one it survives. (Comparing
/// pg_stat_activity's xact_start with query_start looks simpler but is
/// wrong: under the extended query protocol the transaction starts at Parse
/// and query_start is stamped at Execute, so they always differ.)
Future<void> ensureNoOpenTransaction(DbExecutor executor) async {
  if (isSqliteExecutor(executor)) return;
  final token = '${DateTime.now().microsecondsSinceEpoch}-${_probeCounter++}';
  await executor.execute(
    "SELECT set_config('dbscope.xact_probe', @token, true)",
    named: {'token': token},
  );
  final res = await executor.execute(
    "SELECT current_setting('dbscope.xact_probe', true) = @token",
    named: {'token': token},
  );
  if (res.rows.isNotEmpty && res.rows.first.first == true) {
    throw const MetaSessionBusy(
      'A transaction is open on this connection (BEGIN without COMMIT in a '
      'Query tab?). Commit or roll it back first.',
    );
  }
}

/// [timeout], when set, becomes a server-side `SET LOCAL statement_timeout`
/// on Postgres, so a slow metadata query is actually cancelled rather than
/// left running on the shared connection.
Future<DbResult> executeReadOnly(
  DbExecutor executor,
  String sql, {
  Map<String, Object?>? named,
  Duration? timeout,
  CancelToken? cancelToken,
}) {
  Future<DbResult> run() => named == null || named.isEmpty
      ? executor.execute(sql, cancelToken: cancelToken)
      : executor.execute(sql, named: named, cancelToken: cancelToken);

  if (!canFenceReadOnly(executor)) return run();

  return withMetaSession(executor, () async {
    if (isSqliteExecutor(executor)) {
      // Restore whatever the session had: a read-only connection already
      // has query_only on, and must keep it.
      final before = await executor.execute('PRAGMA query_only');
      final wasOn =
          before.rows.isNotEmpty && '${before.rows.first.first}' == '1';
      if (!wasOn) await executor.execute('PRAGMA query_only = ON');
      try {
        return await run();
      } finally {
        if (!wasOn) await executor.execute('PRAGMA query_only = OFF');
      }
    }

    await ensureNoOpenTransaction(executor);
    await executor.execute('BEGIN TRANSACTION READ ONLY');
    try {
      if (timeout != null) {
        await executor.execute(
          'SET LOCAL statement_timeout = ${timeout.inMilliseconds}',
        );
      }
      final result = await run();
      await executor.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        await executor.execute('ROLLBACK');
      } catch (_) {
        // The original error is the one worth reporting.
      }
      rethrow;
    }
  });
}

// Runs statements on one Postgres connection with the two things
// `Connection.execute` can't do: stop a statement that is already running, and
// keep a huge result from ever reaching the client.

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:postgres/postgres.dart' as pg;
// The driver's on-demand cancel is only on the implementation class. It sends
// the protocol's CancelRequest, so it needs no second login and works through
// PgBouncer and the Cloud SQL proxy. A typed import rather than a dynamic call:
// if a driver upgrade removes it, this stops compiling instead of failing at
// the moment a user presses Stop.
// ignore: implementation_imports
import 'package:postgres/src/v3/connection.dart' show PgConnectionImplementation;

/// A CancelRequest that lands while the statement is still being parsed, or
/// between two statements, does nothing, so it is sent again until the
/// statement ends.
const _kCancelRetryInterval = Duration(seconds: 1);

/// How a [RowCap] is enforced. The choice depends on what the statement does,
/// which the caller knows.
enum RowCapMode {
  /// Read every row and drop those past the limit. For a statement that has to
  /// run to the end, such as a write with `RETURNING`. The server still sends
  /// everything: a large result takes as long as it takes, and while it arrives
  /// the isolate has little time for anything else.
  readAndDrop,

  /// A plain read: the server stops producing rows at the limit.
  stopAtLimit,
}

/// A limit on the rows one statement may return. The backend stops keeping
/// rows at the limit, so a huge result can't exhaust memory.
class RowCap {
  const RowCap(this.maxRows, {required this.mode});

  final int maxRows;
  final RowCapMode mode;
}

/// What one statement produced.
class PgRun {
  const PgRun({
    required this.rows,
    required this.schema,
    required this.affectedRows,
    required this.truncated,
    required this.cancelled,
  });

  const PgRun.wasCancelled()
    : rows = const [],
      schema = null,
      affectedRows = 0,
      truncated = false,
      cancelled = true;

  final List<pg.ResultRow> rows;

  /// Null only when the statement was cancelled.
  final pg.ResultSchema? schema;
  final int affectedRows;

  /// More rows existed than the [RowCap] allowed.
  final bool truncated;

  /// The caller asked to cancel and the statement ended early because of it.
  final bool cancelled;
}

/// One connection's statements. Share one per connection: it knows which
/// statement is at the front of the driver's queue, and a CancelRequest stops
/// whatever is running on the server, so cancelling a statement that is still
/// queued must wait until its turn or it would stop someone else's.
class PgSession {
  PgSession(this._connection);

  final pg.Connection _connection;
  final _active = ListQueue<_ActiveStatement>();

  /// Runs [sql] with at most one of [positional] (`$1`) and [named] (`@name`).
  ///
  /// When [cancelRequested] completes the statement is cancelled on the server
  /// and the result has [PgRun.cancelled] set.
  Future<PgRun> run(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    RowCap? rowCap,
    Future<void>? cancelRequested,
  }) async {
    final statement = _ActiveStatement(_sendCancel);
    _active.add(statement);
    unawaited(
      cancelRequested?.then((_) {
        statement.cancelRequested = true;
        _cancelIfFront(statement);
      }),
    );
    final parameters = named ?? positional;
    Object query(String text) => named != null
        ? pg.Sql.named(text)
        : positional != null
        ? pg.Sql(text)
        : text;
    try {
      final cap = rowCap;
      if (cap == null) {
        final result = await _connection.execute(query(sql), parameters: parameters);
        return PgRun(
          rows: result,
          schema: result.schema,
          affectedRows: result.affectedRows,
          truncated: false,
          cancelled: false,
        );
      }
      switch (cap.mode) {
        case RowCapMode.readAndDrop:
          return await _readAndDrop(query(sql), parameters, cap.maxRows);
        case RowCapMode.stopAtLimit:
          return await _stopAtLimit(query, sql, parameters, cap.maxRows);
      }
    } on pg.PgException {
      if (statement.cancelRequested) return const PgRun.wasCancelled();
      rethrow;
    } finally {
      statement.finish();
      _active.remove(statement);
      if (_active.isNotEmpty) _cancelIfFront(_active.first);
    }
  }

  Future<PgRun> _readAndDrop(Object query, Object? parameters, int maxRows) async {
    final prepared = await _connection.prepare(query);
    try {
      final rows = <pg.ResultRow>[];
      var truncated = false;
      final subscription = prepared.bind(parameters).listen((row) {
        if (rows.length < maxRows) {
          rows.add(row);
        } else {
          truncated = true;
        }
      });
      try {
        await subscription.asFuture<void>();
      } finally {
        await subscription.cancel();
      }
      return PgRun(
        rows: rows,
        schema: await subscription.schema,
        affectedRows: await subscription.affectedRows,
        truncated: truncated,
        cancelled: false,
      );
    } finally {
      await prepared.dispose();
    }
  }

  /// Wraps the read so the server only ever produces the rows asked for. One
  /// row past the limit shows whether there were more. The newlines keep a
  /// trailing `--` comment from swallowing the closing bracket.
  ///
  /// Two things that look simpler are wrong. Cancelling once enough rows have
  /// arrived: with a socket that always has data ready, a Dart isolate gets no
  /// turn to open the cancel connection, so a million-row flood runs on and
  /// freezes the UI. A cursor: it needs a transaction, and on a connection
  /// shared by every tab another tab's `BEGIN` becomes a no-op inside it, so
  /// its COMMIT would commit that tab's work.
  Future<PgRun> _stopAtLimit(
    Object Function(String) query,
    String sql,
    Object? parameters,
    int maxRows,
  ) async {
    final result = await _connection.execute(
      query('SELECT * FROM (\n$sql\n) AS dbscope_capped LIMIT ${maxRows + 1}'),
      parameters: parameters,
    );
    final truncated = result.length > maxRows;
    final rows = truncated ? result.sublist(0, maxRows) : result;
    return PgRun(
      rows: rows,
      schema: result.schema,
      affectedRows: rows.length,
      truncated: truncated,
      cancelled: false,
    );
  }

  void _cancelIfFront(_ActiveStatement statement) {
    if (statement.cancelRequested && identical(_active.firstOrNull, statement)) {
      statement.stop();
    }
  }

  Future<void> _sendCancel() async {
    try {
      // Internal to the driver; see the import above for why it is used.
      // ignore: invalid_use_of_internal_member
      await (_connection as PgConnectionImplementation).cancelPendingStatement();
    } catch (error, stackTrace) {
      // The statement simply runs on. The caller's fallback is to close the
      // connection.
      developer.log('Cancel request failed', error: error, stackTrace: stackTrace);
    }
  }
}

class _ActiveStatement {
  _ActiveStatement(this._sendCancel);

  final Future<void> Function() _sendCancel;
  Timer? _retry;
  var _finished = false;
  var cancelRequested = false;

  void stop() {
    if (_finished || _retry != null) return;
    _retry = Timer.periodic(_kCancelRetryInterval, (_) => unawaited(_sendCancel()));
    unawaited(_sendCancel());
  }

  void finish() {
    _finished = true;
    _retry?.cancel();
  }
}

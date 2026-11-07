import 'package:sqlite3/sqlite3.dart' as sq;

import '../query/cancel_token.dart';
import 'executor.dart';
import 'sqlite_kind.dart';
import 'sqlite_param_translator.dart';
import 'sqlite_progress.dart';
import 'statement_timeout.dart';

export 'sqlite_kind.dart';

/// DbExecutor backed by package:sqlite3 (FFI to bundled libsqlite3).
///
/// Capabilities:
/// - sessionReadOnly: true (PRAGMA query_only = 1)
/// - cancelsRunningStatement: false (sqlite3 Dart is sync FFI, so a running
/// statement blocks the isolate and nothing can
/// fire the token. Honour it before returning
/// the row set as a best effort.)
/// - dml/transactions: true
///
/// `$N` and `@name` are rewritten to SQLite's `?N` and `:name` so the
/// existing Postgres-flavoured call sites work unchanged.
class SqliteExecutor implements DbExecutor, StatementTimeoutCapable {
  SqliteExecutor(this._db) {
    _registerFunctions(_db);
  }
  final sq.Database _db;

  /// Case-insensitive regex match, `dbscope_iregexp(pattern, value)`: the
  /// SQLite spelling of Postgres `value ~* pattern` (SQLite ships no regex
  /// function). NULL in, NULL out, like the operator.
  static const String iregexpFunction = kSqliteIRegexpFunction;

  static void _registerFunctions(sq.Database db) {
    final cache = <String, RegExp>{};
    db.createFunction(
      functionName: iregexpFunction,
      argumentCount: const sq.AllowedArgumentCount(2),
      deterministic: true,
      function: (args) {
        final pattern = args[0];
        final value = args[1];
        if (pattern == null || value == null) return null;
        final re = cache.putIfAbsent(
          '$pattern',
          () => RegExp('$pattern', caseSensitive: false),
        );
        return re.hasMatch('$value') ? 1 : 0;
      },
    );
  }

  @override
  Future<T> withStatementTimeout<T>(
    Duration timeout,
    Future<T> Function() body,
  ) async {
    try {
      return await runWithSqliteDeadline(_db.handle, timeout, body);
    } on sq.SqliteException catch (e) {
      if (e.resultCode == kSqliteInterrupt) throw StatementTimedOut(timeout);
      rethrow;
    }
  }
  var _closed = false;

  @override
  String get kind => kSqliteKind;

  @override
  bool get isOpen => !_closed;

  @override
  DbCapabilities get capabilities => const DbCapabilities(
    sessionReadOnly: true,
    dml: true,
    transactions: true,
  );

  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
    RowCap? rowCap,
  }) async {
    if (_closed) {
      throw StateError('SqliteExecutor is closed.');
    }
    if (rowCap != null) {
      return _runCapped(
        named != null ? translateNamedToSqlite(sql) : positional != null ? translatePositionalToSqlite(sql) : sql,
        rowCap,
        positional == null ? null : [for (final value in positional) _toSqlValue(value)],
        named?.map((key, value) => MapEntry(':$key', _toSqlValue(value))),
      );
    }
    if (named != null) {
      final rewritten = translateNamedToSqlite(sql);
      final params = <String, Object?>{};
      named.forEach((key, value) {
        params[':$key'] = _toSqlValue(value);
      });
      return _runPrepared(
        rewritten,
        namedParams: params,
        cancelToken: cancelToken,
      );
    }
    if (positional != null) {
      final rewritten = translatePositionalToSqlite(sql);
      final params = [for (final value in positional) _toSqlValue(value)];
      return _runPrepared(
        rewritten,
        positionalParams: params,
        cancelToken: cancelToken,
      );
    }
    return _runRaw(sql, cancelToken: cancelToken);
  }

  DbResult _runRaw(String sql, {CancelToken? cancelToken}) {
    // Param-less call path. The query tab routes everything (DDL/DML and
    // SELECT) through here when the SQL doesn't carry placeholders. For
    // DML we need `_db.updatedRows` to surface the real affected count;
    // for SELECT we fall back to the row count from the result set.
    final changesBefore = _totalChanges();
    final result = _db.select(sql);
    if (cancelToken?.isCancelled ?? false) {
      return const DbResult(columns: [], rows: []);
    }
    final base = _resultFromSelect(result);
    if (base.columns.isEmpty) {
      return DbResult(
        columns: base.columns,
        rows: base.rows,
        affectedRows: _changedRows(changesBefore),
      );
    }
    return base;
  }

  DbResult _runPrepared(
    String sql, {
    List<Object?>? positionalParams,
    Map<String, Object?>? namedParams,
    CancelToken? cancelToken,
  }) {
    final statement = _db.prepare(sql);
    final changesBefore = _totalChanges();
    try {
      // Always step through `select`: it is safe for statements that return
      // no rows, and it never throws a result set away. Guessing from the
      // leading keyword missed SQL that starts with a comment or a
      // parenthesis, and a `RETURNING` after a newline.
      final resultSet = positionalParams != null
          ? statement.select(positionalParams)
          : statement.selectWith(
              sq.StatementParameters.named(namedParams ?? const {}),
            );
      if (cancelToken?.isCancelled ?? false) {
        return const DbResult(columns: [], rows: []);
      }
      if (resultSet.columnNames.isEmpty) {
        return DbResult(
          columns: const [],
          rows: const [],
          affectedRows: _changedRows(changesBefore),
        );
      }
      return _resultFromSelect(resultSet);
    } finally {
      statement.dispose();
    }
  }

  /// Steps the statement by hand so rows past [cap] are never held. A plain
  /// read stops there. [RowCapMode.readAndDrop] steps on to the end, like the
  /// other backends, though SQLite has already made a write's changes by its
  /// first step.
  DbResult _runCapped(
    String sql,
    RowCap cap,
    List<Object?>? positionalParams,
    Map<String, Object?>? namedParams,
  ) {
    final statement = _db.prepare(sql);
    final changesBefore = _totalChanges();
    try {
      final cursor = namedParams != null
          ? statement.iterateWith(sq.StatementParameters.named(namedParams))
          : statement.selectCursor(positionalParams ?? const []);
      final rows = <List<Object?>>[];
      var truncated = false;
      while (cursor.moveNext()) {
        if (rows.length < cap.maxRows) {
          rows.add(List<Object?>.of(cursor.current.values));
          continue;
        }
        truncated = true;
        if (cap.mode != RowCapMode.readAndDrop) break;
      }
      if (cursor.columnNames.isEmpty) {
        return DbResult(columns: const [], rows: const [], affectedRows: _changedRows(changesBefore));
      }
      return DbResult(
        columns: [for (final name in cursor.columnNames) DbColumn(name: name)],
        rows: rows,
        affectedRows: rows.length,
        truncated: truncated,
      );
    } finally {
      statement.dispose();
    }
  }

  int _totalChanges() =>
      (_db.select('SELECT total_changes()').first.columnAt(0) as int?) ?? 0;

  /// Rows the statement just run inserted, updated or deleted.
  /// `sqlite3_changes()` alone keeps the count of the last INSERT / UPDATE /
  /// DELETE, so a `CREATE TABLE` after an UPDATE of 5 rows reported 5; it
  /// only counts when this statement changed something.
  int _changedRows(int totalChangesBefore) =>
      _totalChanges() == totalChangesBefore ? 0 : _db.updatedRows;

  DbResult _resultFromSelect(sq.ResultSet resultSet) {
    final columns = <DbColumn>[];
    for (var i = 0; i < resultSet.columnNames.length; i++) {
      columns.add(
        DbColumn(
          name: resultSet.columnNames[i],
        ),
      );
    }
    final rows = <List<Object?>>[
      for (final row in resultSet.rows) List<Object?>.from(row),
    ];
    // SELECTs report affectedRows = 0; RETURNING clauses on DML will be
    // reported as len(rows) so callers downstream of insertRow get the
    // intuitive count.
    return DbResult(columns: columns, rows: rows, affectedRows: rows.length);
  }

  @override
  Future<void> setReadOnly({required bool readOnly}) async {
    if (_closed) return;
    _db.execute('PRAGMA query_only = ${readOnly ? 1 : 0}');
  }

  @override
  Future<void> close({bool force = false}) async {
    if (_closed) return;
    _closed = true;
    try {
      _db.dispose();
    } catch (_) {}
  }

  /// Convert Dart values to types the sqlite3 binding accepts. The
  /// binding handles String, int, double, Uint8List, bool, null natively;
  /// anything else (DateTime, BigInt, custom objects from the grid edit
  /// path) goes through toString so the user's intent isn't silently
  /// dropped.
  static Object? _toSqlValue(Object? value) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is BigInt) return value.toString();
    if (value is List<int>) return value;
    return value.toString();
  }
}

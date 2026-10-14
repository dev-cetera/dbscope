import 'package:sqlite3/sqlite3.dart' as sq;

import '../query/cancel_token.dart';
import 'executor.dart';
import 'sqlite_kind.dart';
import 'sqlite_param_translator.dart';

export 'sqlite_kind.dart';

/// DbExecutor backed by package:sqlite3 (FFI to bundled libsqlite3).
///
/// Capabilities:
/// - sessionReadOnly: true (PRAGMA query_only = 1)
/// - cancelByClose: false (sqlite3 Dart is sync FFI; the Stop button
/// can't preempt an in-flight query. Honour
/// the token before returning the row set as
/// a best effort.)
/// - dml/transactions: true
///
/// `$N` and `@name` are rewritten to SQLite's `?N` and `:name` so the
/// existing Postgres-flavoured call sites work unchanged.
class SqliteExecutor implements DbExecutor {
  SqliteExecutor(this._db);
  final sq.Database _db;
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
  }) async {
    if (_closed) {
      throw StateError('SqliteExecutor is closed.');
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
    final result = _db.select(sql);
    if (cancelToken?.isCancelled ?? false) {
      return const DbResult(columns: [], rows: []);
    }
    final base = _resultFromSelect(result);
    if (base.columns.isEmpty) {
      return DbResult(
        columns: base.columns,
        rows: base.rows,
        affectedRows: _db.updatedRows,
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
    try {
      final isQuery = _statementProducesRows(statement);
      if (isQuery) {
        final resultSet = positionalParams != null
            ? statement.select(positionalParams)
            : statement.selectWith(
                sq.StatementParameters.named(namedParams ?? const {}),
              );
        if (cancelToken?.isCancelled ?? false) {
          return const DbResult(columns: [], rows: []);
        }
        return _resultFromSelect(resultSet);
      } else {
        if (positionalParams != null) {
          statement.execute(positionalParams);
        } else {
          statement.executeWith(
            sq.StatementParameters.named(namedParams ?? const {}),
          );
        }
        return DbResult(
          columns: const [],
          rows: const [],
          affectedRows: _db.updatedRows,
        );
      }
    } finally {
      statement.dispose();
    }
  }

  bool _statementProducesRows(sq.PreparedStatement statement) {
    // The sqlite3 Dart binding doesn't expose a "is read-only" flag for a
    // prepared stmt across all versions, so peek at the leading keyword.
    // Catalog SQL and the pager generate stable shapes so this is
    // adequate.
    final source = statement.sql.trimLeft();
    final upper = source.toUpperCase();
    if (upper.startsWith('SELECT')) return true;
    if (upper.startsWith('WITH')) return true;
    if (upper.startsWith('PRAGMA')) return true;
    if (upper.startsWith('VALUES')) return true;
    if (upper.startsWith('EXPLAIN')) return true;
    // INSERT/UPDATE/DELETE with RETURNING also produce rows.
    if (upper.contains(' RETURNING ')) return true;
    return false;
  }

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

// DbExecutor for an on-device SQLite file accessed via adb/devicectl.
//
// Lifecycle:
// - Open: pull <name>.db (+ -wal/-shm if present), checkpoint the WAL
// into the main file, set journal_mode=DELETE so subsequent local
// writes don't recreate WAL sidecars, then wrap a `package:sqlite3`
// Database in a regular SqliteExecutor.
// - Execute: delegate to the inner executor. If the statement changed
// the file (rows or schema changed, or a non-read keyword such as
// VACUUM), push the file back to the device once no transaction is
// open, and delete any stale -wal/-shm sidecars there.
// - Close: dispose the inner executor and remove the temp dir.
//
// Concurrency caveat (documented in the profile dialog too): the file is
// a snapshot. Writes from the device app between pull and push are lost,
// and pushing while the app holds the DB open can corrupt it. The dialog
// nags the user to force-stop the app before editing.

import 'dart:io';

import 'package:app_data_explorer/app_data_explorer.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/db/sqlite_executor.dart';
import 'package:dbscope/db/statement_timeout.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope/util/sql_parse.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

class DeviceSqliteExecutor implements DbExecutor, StatementTimeoutCapable {
  DeviceSqliteExecutor._({
    required this.backend,
    required this.remoteDbPath,
    required Directory temporaryDirectory,
    required SqliteExecutor inner,
    required sq.Database db,
    required String localDbPath,
  })  : _temporaryDirectory = temporaryDirectory,
        _inner = inner,
        _db = db,
        _localDbPath = localDbPath;

  final Backend backend;
  final String remoteDbPath;

  final Directory _temporaryDirectory;
  final SqliteExecutor _inner;
  final sq.Database _db;
  final String _localDbPath;
  var _closed = false;

  /// The local file has changes the device hasn't received yet.
  var _unpushed = false;

  /// Pulls [remoteDbPath] (and best-effort its `-wal` sidecar — never the
  /// `-shm`, sqlite always rebuilds it) into a fresh temp directory, then
  /// opens it. Pulling .db and -wal is inherently non-atomic over an adb
  /// / devicectl roundtrip, so we attempt the WAL-included path first; if
  /// sqlite reports inconsistency between the two we fall back to opening
  /// .db alone. That fallback loses any transactions that lived only in
  /// the pulled -wal, but the alternative is refusing to open at all.
  static Future<DeviceSqliteExecutor> open({
    required Backend backend,
    required String remoteDbPath,
  }) async {
    final temporaryDirectory = await Directory.systemTemp.createTemp('dbscope_device_');
    final localDbPath = '${temporaryDirectory.path}/${_basename(remoteDbPath)}';
    final walPath = '$localDbPath-wal';
    try {
      await backend.pull(remoteDbPath, localDbPath);
      try {
        await backend.pull('$remoteDbPath-wal', walPath);
      } catch (_) {
        // -wal absent on device — fine. The .db is consistent on its
        // own when no checkpoint is pending.
      }
      sq.Database? db;
      try {
        db = _openAndPrepare(localDbPath);
      } catch (_) {
        // Most likely a stale -wal we just pulled is inconsistent with
        // .db (the two files moved between adb pulls). Drop the WAL and
        // open .db alone — sqlite will read it without a -wal.
        try {
          final wal = File(walPath);
          if (wal.existsSync()) await wal.delete();
          final shm = File('$localDbPath-shm');
          if (shm.existsSync()) await shm.delete();
        } catch (_) {}
        db = _openAndPrepare(localDbPath);
      }
      return DeviceSqliteExecutor._(
        backend: backend,
        remoteDbPath: remoteDbPath,
        temporaryDirectory: temporaryDirectory,
        inner: SqliteExecutor(db),
        db: db,
        localDbPath: localDbPath,
      );
    } catch (_) {
      try {
        await temporaryDirectory.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// Opens [path] with `package:sqlite3`, folds any -wal into the main
  /// file via `wal_checkpoint(TRUNCATE)`, then switches to rollback
  /// journal mode so subsequent writes don't recreate WAL sidecars on
  /// the local snapshot. Throws (and disposes `db`) if anything in the
  /// preparation step fails, so the caller's fallback path sees a
  /// consistent "couldn't open" signal.
  static sq.Database _openAndPrepare(String path) {
    final db = sq.sqlite3.open(path);
    try {
      // If a -wal exists alongside .db, this both validates them
      // against each other (throws "malformed" on mismatch) and merges
      // pending WAL frames into the main file.
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute('PRAGMA foreign_keys = ON');
      return db;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  @override
  String get kind => kSqliteKind;

  @override
  bool get isOpen => !_closed;

  @override
  DbCapabilities get capabilities => const DbCapabilities(
        // PRAGMA query_only on the local snapshot — affects local edits
        // before they get pushed.
        sessionReadOnly: true,
        // Writes work — they roundtrip through the device on each call.
        dml: true,
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
      throw StateError('DeviceSqliteExecutor is closed.');
    }
    final changesBefore = _totalChanges();
    final schemaBefore = _schemaVersion();
    final result = await _inner.execute(
      sql,
      positional: positional,
      named: named,
      cancelToken: cancelToken,
      rowCap: rowCap,
    );
    if (_changedFile(sql, changesBefore, schemaBefore)) _unpushed = true;
    // Inside an open transaction (a `BEGIN` from a Query tab) the change
    // isn't committed yet: pushing now would send the device a file the
    // ROLLBACK may still undo. Push once the transaction has ended.
    if (_unpushed && _db.autocommit) {
      await _pushBack();
      _unpushed = false;
    }
    return result;
  }

  @override
  Future<T> withStatementTimeout<T>(
    Duration timeout,
    Future<T> Function() body,
  ) => _inner.withStatementTimeout(timeout, body);

  @override
  Future<void> setReadOnly({required bool readOnly}) => _inner.setReadOnly(readOnly: readOnly);

  @override
  Future<void> close({bool force = false}) async {
    if (_closed) return;
    _closed = true;
    try {
      await _inner.close(force: force);
    } catch (_) {}
    try {
      await _temporaryDirectory.delete(recursive: true);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------

  Future<void> _pushBack() async {
    // Make sure any open transaction is flushed and the WAL is folded
    // back into the main file before we push. journal_mode=DELETE means
    // there shouldn't be a WAL, but checkpoint is a no-op in that mode.
    try {
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    await backend.push(_localDbPath, remoteDbPath);
    // The on-device WAL/SHM are stale relative to the new main file. If
    // we leave them, sqlite on the device might apply pre-push WAL on
    // top of the new file and corrupt it. Delete proactively; missing
    // siblings are not an error.
    for (final suffix in const ['-wal', '-shm']) {
      try {
        await backend.rm('$remoteDbPath$suffix');
      } catch (_) {}
    }
  }

  /// `total_changes()` counts every row INSERT / UPDATE / DELETE on this
  /// connection, including ones inside a `WITH … AS (DELETE …)`.
  int _totalChanges() =>
      (_db.select('SELECT total_changes()').first.columnAt(0) as int?) ?? 0;

  /// Bumped by every schema change (CREATE / ALTER / DROP).
  int _schemaVersion() =>
      (_db.select('PRAGMA schema_version').first.columnAt(0) as int?) ?? 0;

  /// Whether [sql] changed the local file, so the device needs it back.
  ///
  /// Decided from what the statement did, not from the result's row
  /// count: the inner executor reports a SELECT's row count as
  /// `affectedRows`, so reading three rows looked like three writes and
  /// pushed the whole file to the phone after every grid page. Row and
  /// schema changes are counted by SQLite itself; the leading keyword only
  /// covers writes neither counter sees (VACUUM, `PRAGMA user_version = 2`).
  bool _changedFile(String sql, int changesBefore, int schemaBefore) {
    if (_totalChanges() != changesBefore) return true;
    if (_schemaVersion() != schemaBefore) return true;
    return keywordMayWrite(sql);
  }

  /// Statements that may write without counting a changed row or a schema
  /// change. Reads, and transaction control (whose writes were counted by
  /// the statements inside the transaction), are false.
  static bool keywordMayWrite(String sql) {
    final words = bareWords(sql, dialect: SqlDialect.sqlite);
    if (words.isEmpty) return false;
    switch (words.first) {
      case 'SELECT':
      case 'WITH':
      case 'EXPLAIN':
      case 'VALUES':
      case 'BEGIN':
      case 'COMMIT':
      case 'END':
      case 'ROLLBACK':
      case 'SAVEPOINT':
      case 'RELEASE':
        return false;
      case 'PRAGMA':
        // Some PRAGMAs write (`user_version = N`); a read has no `=`.
        return stripCommentsAndLeading(sql, dialect: SqlDialect.sqlite).contains('=');
      default:
        // INSERT/UPDATE/DELETE/REPLACE/CREATE/DROP/ALTER/VACUUM/REINDEX/
        // ANALYZE (writes sqlite_stat1 without counting a change)/…
        return true;
    }
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

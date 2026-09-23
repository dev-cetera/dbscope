// DbExecutor for an on-device SQLite file accessed via adb/devicectl.
//
// Lifecycle:
// - Open: pull <name>.db (+ -wal/-shm if present), checkpoint the WAL
// into the main file, set journal_mode=DELETE so subsequent local
// writes don't recreate WAL sidecars, then wrap a `package:sqlite3`
// Database in a regular SqliteExecutor.
// - Execute: delegate to the inner executor. If the statement was a
// write (affectedRows > 0, or any non-SELECT), push the file back to
// the device and delete any stale -wal/-shm sidecars there.
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
import 'package:dbscope/query/cancel_token.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

class DeviceSqliteExecutor implements DbExecutor {
  DeviceSqliteExecutor._({
    required this.backend,
    required this.remoteDbPath,
    required Directory tmpDir,
    required SqliteExecutor inner,
    required sq.Database db,
    required String localDbPath,
  })  : _tmpDir = tmpDir,
        _inner = inner,
        _db = db,
        _localDbPath = localDbPath;

  final Backend backend;
  final String remoteDbPath;

  final Directory _tmpDir;
  final SqliteExecutor _inner;
  final sq.Database _db;
  final String _localDbPath;
  bool _closed = false;

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
    final tmpDir = await Directory.systemTemp.createTemp('dbscope_device_');
    final localDbPath = '${tmpDir.path}/${_basename(remoteDbPath)}';
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
          if (await wal.exists()) await wal.delete();
          final shm = File('$localDbPath-shm');
          if (await shm.exists()) await shm.delete();
        } catch (_) {}
        db = _openAndPrepare(localDbPath);
      }
      return DeviceSqliteExecutor._(
        backend: backend,
        remoteDbPath: remoteDbPath,
        tmpDir: tmpDir,
        inner: SqliteExecutor(db),
        db: db,
        localDbPath: localDbPath,
      );
    } catch (_) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// Opens [path] with `package:sqlite3`, folds any -wal into the main
  /// file via `wal_checkpoint(TRUNCATE)`, then switches to rollback
  /// journal mode so subsequent writes don't recreate WAL sidecars on
  /// the local snapshot. Throws (and disposes [db]) if anything in the
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
        // Local sqlite3 is sync FFI; the Stop button can't preempt.
        cancelByClose: false,
        // Writes work — they roundtrip through the device on each call.
        dml: true,
        // sqlite3 supports transactions, but dbscope's catalog/grid edit
        // paths drive them via implicit autocommit and we want every
        // committed change pushed immediately. Disabling here keeps the
        // UI honest: it won't BEGIN a multi-statement TX that would only
        // push at COMMIT time. (Re-enable if write batching is needed.)
        transactions: false,
      );

  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
  }) async {
    if (_closed) {
      throw StateError('DeviceSqliteExecutor is closed.');
    }
    final result = await _inner.execute(
      sql,
      positional: positional,
      named: named,
      cancelToken: cancelToken,
    );
    if (_writesToFile(sql, result)) {
      await _pushBack();
    }
    return result;
  }

  @override
  Future<void> setReadOnly(bool readOnly) => _inner.setReadOnly(readOnly);

  @override
  Future<void> close({bool force = false}) async {
    if (_closed) return;
    _closed = true;
    try {
      await _inner.close(force: force);
    } catch (_) {}
    try {
      await _tmpDir.delete(recursive: true);
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

  /// Best-effort detection of "this statement mutated the file". SELECT,
  /// EXPLAIN, PRAGMA-as-query, etc. don't need a push. DDL (CREATE/DROP)
  /// reports affectedRows = 0 but does mutate, so we also peek at the
  /// statement keyword.
  static bool _writesToFile(String sql, DbResult result) {
    if (result.affectedRows > 0) return true;
    final trimmed = _strip(sql).toUpperCase();
    if (trimmed.startsWith('SELECT')) return false;
    if (trimmed.startsWith('WITH')) return false;
    if (trimmed.startsWith('EXPLAIN')) return false;
    if (trimmed.startsWith('VALUES')) return false;
    if (trimmed.startsWith('PRAGMA')) {
      // Some PRAGMAs mutate (e.g. user_version = N, journal_mode = X).
      // Detect by presence of '='.
      return trimmed.contains('=');
    }
    // Anything else (CREATE/ALTER/DROP/INSERT/UPDATE/DELETE/REPLACE/
    // VACUUM/REINDEX/...) is a mutation.
    return true;
  }

  static String _strip(String sql) {
    var s = sql.trimLeft();
    // Strip single-line comments.
    while (s.startsWith('--')) {
      final nl = s.indexOf('\n');
      if (nl < 0) return '';
      s = s.substring(nl + 1).trimLeft();
    }
    return s;
  }

  static String _basename(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }
}

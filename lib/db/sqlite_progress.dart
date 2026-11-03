// Statement deadlines for SQLite via `sqlite3_progress_handler`.
//
// package:sqlite3 runs statements synchronously on the calling isolate and
// exposes neither `sqlite3_interrupt` nor a progress handler, so a runaway
// statement could never be stopped. SQLite calls the progress handler every
// [_kOpsPerCheck] VM instructions on the same thread that is running the
// statement, so a plain `Pointer.fromFunction` callback that compares the
// clock with the active deadline is enough; returning non-zero makes the
// statement fail with SQLITE_INTERRUPT.

import 'dart:ffi';

import 'package:sqlite3/open.dart' as sqlite_open;

typedef _ProgressNative = Int Function(Pointer<Void>);
typedef _SetHandlerNative =
    Void Function(
      Pointer<Void> db,
      Int ops,
      Pointer<NativeFunction<_ProgressNative>> handler,
      Pointer<Void> arg,
    );
typedef _SetHandlerDart =
    void Function(
      Pointer<Void> db,
      int ops,
      Pointer<NativeFunction<_ProgressNative>> handler,
      Pointer<Void> arg,
    );

const _kOpsPerCheck = 10000;

/// SQLite's result code for an interrupted statement.
const kSqliteInterrupt = 9;

/// Active deadline per database handle address. The handler's user-data
/// argument is the handle itself, so each connection checks its own.
final _deadlines = <int, DateTime>{};

int _onProgress(Pointer<Void> db) {
  final deadline = _deadlines[db.address];
  return deadline != null && DateTime.now().isAfter(deadline) ? 1 : 0;
}

_SetHandlerDart? _setHandlerCache;
var _lookedUp = false;

_SetHandlerDart? get _setHandler {
  if (_lookedUp) return _setHandlerCache;
  _lookedUp = true;
  try {
    // The same opener package:sqlite3 itself uses, so this is the library
    // that owns the database handles we pass in.
    _setHandlerCache = sqlite_open.open
        .openSqlite()
        .lookupFunction<_SetHandlerNative, _SetHandlerDart>(
          'sqlite3_progress_handler',
        );
  } catch (_) {
    _setHandlerCache = null;
  }
  return _setHandlerCache;
}

/// Runs [body] with a progress handler on [dbHandle] that aborts the running
/// statement once [timeout] has passed. When the handler can't be installed
/// (the symbol is missing), [body] runs without a deadline.
Future<T> runWithSqliteDeadline<T>(
  Pointer<void> dbHandle,
  Duration timeout,
  Future<T> Function() body,
) async {
  final setHandler = _setHandler;
  if (setHandler == null) return body();
  final db = dbHandle.cast<Void>();
  final previous = _deadlines[db.address];
  _deadlines[db.address] = DateTime.now().add(timeout);
  setHandler(
    db,
    _kOpsPerCheck,
    Pointer.fromFunction<_ProgressNative>(_onProgress, 1),
    db,
  );
  try {
    return await body();
  } finally {
    if (previous == null) {
      _deadlines.remove(db.address);
      setHandler(db, 0, nullptr, nullptr);
    } else {
      _deadlines[db.address] = previous;
    }
  }
}

// Cross-isolate file helpers for read-modify-write of small JSON files.
//
// Every dbscope window is its own isolate inside one process, so OS file
// locks (fcntl, which is per process) can't keep two windows apart. An
// exclusively created lock file can: `create(exclusive: true)` is an
// atomic O_EXCL open that fails for everyone but the first caller.

import 'dart:async';
import 'dart:io';

/// A lock older than this is taken to belong to a window that died while
/// holding it, and is broken. Every critical section here is one small
/// read and write, far shorter than this.
const _kStaleLockAge = Duration(seconds: 10);

/// Runs [body] while holding the lock file `<target>.lock`, waiting for
/// another isolate (or process) that holds it. Gives up waiting after
/// [timeout] and runs [body] anyway, so a stuck lock can never stop a save.
Future<T> withFileLock<T>(
  String targetPath,
  Future<T> Function() body, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final lock = File('$targetPath.lock');
  final deadline = DateTime.now().add(timeout);
  var held = false;
  var delay = const Duration(milliseconds: 5);
  while (true) {
    try {
      await lock.create(exclusive: true);
      held = true;
      break;
    } on FileSystemException {
      try {
        final stat = lock.statSync();
        if (stat.type != FileSystemEntityType.notFound &&
            DateTime.now().difference(stat.modified) > _kStaleLockAge) {
          lock.deleteSync();
          continue;
        }
      } on FileSystemException {
        continue;
      }
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(delay);
      if (delay < const Duration(milliseconds: 100)) delay *= 2;
    }
  }
  try {
    return await body();
  } finally {
    if (held) {
      try {
        lock.deleteSync();
      } on FileSystemException {
        // Already broken as stale by someone else.
      }
    }
  }
}

/// Writes [contents] to [file] atomically: a uniquely named temp file in
/// the same directory, flushed, then renamed over [file]. A crash mid-write
/// leaves the previous file intact, and two writers never share a temp.
Future<void> writeFileAtomically(File file, String contents) async {
  final temp = File(
    '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await temp.writeAsString(contents, flush: true);
    await temp.rename(file.path);
  } catch (_) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Best effort.
    }
    rethrow;
  }
}

/// Moves an unreadable [file] aside to `<name>.corrupt-<timestamp>` so the
/// next write can't overwrite the only copy. Returns the new path, or null
/// when the move failed.
String? preserveCorruptFile(File file) {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final backup = '${file.path}.corrupt-$stamp';
  try {
    file.renameSync(backup);
    return backup;
  } on FileSystemException {
    return null;
  }
}

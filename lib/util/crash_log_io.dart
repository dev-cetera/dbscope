import 'dart:io';

/// Rotate once the log passes this size, keeping one previous file, so a
/// crash loop can't fill the disk.
const int _kMaxBytes = 1024 * 1024;

String? _cachedPath;

/// `~/Library/Logs/dbscope/dbscope.log` on macOS (where Console.app looks),
/// `<temp>/dbscope/dbscope.log` elsewhere.
String? crashLogPath() {
  if (_cachedPath != null) return _cachedPath;
  final home = Platform.environment['HOME'];
  final dir = Platform.isMacOS && home != null && home.isNotEmpty
      ? '$home/Library/Logs/dbscope'
      : '${Directory.systemTemp.path}/dbscope';
  return _cachedPath = '$dir/dbscope.log';
}

/// Appends [entry] to the log. Never throws: failing to log must not turn
/// one error into two.
void appendCrashLog(String entry) {
  final path = crashLogPath();
  if (path == null) return;
  try {
    final file = File(path);
    file.parent.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > _kMaxBytes) {
      file.renameSync('$path.1');
    }
    file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// The folder holding the log, created if missing so it can always be
/// opened, or null when it can't be created.
String? crashLogFolder() {
  final path = crashLogPath();
  if (path == null) return null;
  try {
    return (File(path).parent..createSync(recursive: true)).path;
  } catch (_) {
    return null;
  }
}

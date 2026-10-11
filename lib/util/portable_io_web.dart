// Web stubs. Connection-link import/export is desktop-only; these throw /
// return null so the app still compiles for web.

Future<void> writeTextFile(String path, String content) async =>
    throw UnsupportedError('Writing files is not supported on web.');

String? envValue(String key) => null;

Future<String> readTextFile(String path) async =>
    throw UnsupportedError('Reading files is not supported on web.');

String parentDirectory(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}

String resolveRelativePath(String directory, String relative) =>
    relative.startsWith('/') ? relative : '$directory/$relative';

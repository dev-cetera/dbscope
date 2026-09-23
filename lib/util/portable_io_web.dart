// Web stubs. Connection-link import/export is desktop-only; these throw /
// return null so the app still compiles for web.

Future<void> writeTextFile(String path, String content) async =>
    throw UnsupportedError('Writing files is not supported on web.');

String? envValue(String key) => null;

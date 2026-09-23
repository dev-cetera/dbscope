// Web stub. Save-to-file is gated by kIsWeb in dbml_export_flow.dart so
// this is dead code on web; if it ever fires it's a programmer error.

Future<void> writeDbmlFile(String path, String content) async {
  throw UnsupportedError('writeDbmlFile is not supported on web.');
}

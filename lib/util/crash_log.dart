// Conditional export: a log file on desktop, the browser console on web.
export 'crash_log_io.dart' if (dart.library.js_interop) 'crash_log_web.dart';

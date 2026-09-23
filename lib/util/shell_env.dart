// Conditional export: dart:io on desktop, a stub on web. Same shape
// either way, so UI code can talk about the shell env file without
// caring whether this platform has one.
export 'shell_env_io.dart' if (dart.library.js_interop) 'shell_env_web.dart';

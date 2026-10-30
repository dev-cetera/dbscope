// Conditional export: the macOS self-installer on desktop, a page reload on
// web. Same split as lib/util/portable_io.dart.
export 'update_installer_io.dart' if (dart.library.js_interop) 'update_installer_web.dart';

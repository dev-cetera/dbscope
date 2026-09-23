// Conditional export: dart:io on desktop/mobile, stubs on web. Keeps files
// that only need "write a text file" / "read an env var" web-safe without
// each one carrying its own conditional import.
export 'portable_io_io.dart'
    if (dart.library.js_interop) 'portable_io_web.dart';

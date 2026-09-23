// Conditional import: io build vs web build.
//
// Both files export `platformConnectionPlugins()`; main.dart calls
// that one function regardless of build target.
export 'platform_plugins_io.dart'
    if (dart.library.js_interop) 'platform_plugins_web.dart';

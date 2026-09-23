// Conditional facade: on platforms that have dart:io we use the real
// desktop_multi_window-backed IsolateTransport; on web we use a stub
// that throws if anyone tries to construct it (the web build is
// single-window).

export 'isolate_transport_io.dart'
    if (dart.library.js_interop) 'isolate_transport_web.dart';

// Web stub for IsolateTransport. The web build is a single-window app
// (no desktop_multi_window), so IsolateTransport should never be
// constructed — these types exist only so consuming code compiles.

import 'dart:async';

import 'envelope.dart';
import 'transport.dart';

class WindowRouter {
  WindowRouter._();
  static final instance = WindowRouter._();

  var windowId = 0;

  void ensureInstalled() {}
}

class IsolateTransport implements Transport {
  IsolateTransport({this.targetWindowId = 0}) {
    throw UnsupportedError(
      'IsolateTransport is not supported on the web build.',
    );
  }
  final int targetWindowId;

  @override
  Stream<Envelope> get incoming => const Stream.empty();

  @override
  void send(Envelope envelope) {}

  @override
  Future<void> dispose() async {}
}

// Same signature as the io HostWindowRouter so `main.dart` compiles on
// web; it is never constructed there (guarded by `!kIsWeb`).
class HostWindowRouter {
  HostWindowRouter({required this.dispatch});

  final void Function(
    Envelope envelope,
    int fromWindowId,
    void Function(Envelope) reply,
  )
  dispatch;
}

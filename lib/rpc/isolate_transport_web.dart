// Web stub for IsolateTransport. The web build is a single-window app
// (no desktop_multi_window), so IsolateTransport should never be
// constructed — these types exist only so consuming code compiles.

import 'dart:async';

import 'envelope.dart';
import 'transport.dart';

class WindowRouter {
  WindowRouter._();
  static final WindowRouter instance = WindowRouter._();

  void ensureInstalled() {}
}

class IsolateTransport implements Transport {
  final int targetWindowId;
  IsolateTransport({this.targetWindowId = 0}) {
    throw UnsupportedError(
      'IsolateTransport is not supported on the web build.',
    );
  }

  @override
  Stream<Envelope> get incoming => const Stream.empty();

  @override
  void send(Envelope envelope) {}

  @override
  Future<void> dispose() async {}
}

class HostWindowRouter {
  HostWindowRouter({
    required void Function(
      Envelope envelope,
      int fromWindowId,
      void Function(Envelope) reply,
    )
    dispatch,
  });
}

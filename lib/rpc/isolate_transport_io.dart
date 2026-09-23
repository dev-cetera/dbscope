// IsolateTransport — Transport for subwindows that communicate with the
// host isolate via desktop_multi_window's method channels.
//
// Wire calls:
// subwindow → host: invokeMethod(0, 'rpc.send', <encoded envelope>)
// host → subwindow: invokeMethod(subId, 'rpc.recv', <encoded envelope>)
//
// Both sides use the same method handler hook, so this module owns the
// dispatch to keep registration centralized; consumers add additional
// route handlers via `IsolateTransport.addRoute`.

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import 'envelope.dart';
import 'transport.dart';

typedef WindowRoute =
    Future<dynamic> Function(
      MethodCall call,
      int fromWindowId,
    );

// Singleton router. Set up once per isolate.
class WindowRouter {
  WindowRouter._();
  static final WindowRouter instance = WindowRouter._();

  bool _installed = false;
  final Map<String, WindowRoute> _routes = {};

  void ensureInstalled() {
    if (_installed) return;
    _installed = true;
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      final route = _routes[call.method];
      if (route == null) return null;
      return await route(call, fromWindowId);
    });
  }

  void addRoute(String method, WindowRoute handler) {
    ensureInstalled();
    _routes[method] = handler;
  }
}

class IsolateTransport implements Transport {
  // The window id we send envelopes to. Subwindows send to 0 (host).
  final int targetWindowId;
  // Single-subscription: BackendClient is the only listener. See note
  // on the matching field in LocalTransport for why broadcast is
  // avoided.
  final StreamController<Envelope> _incoming = StreamController<Envelope>();

  IsolateTransport({this.targetWindowId = 0}) {
    WindowRouter.instance.addRoute('rpc.recv', _onRecv);
  }

  Future<dynamic> _onRecv(MethodCall call, int fromWindowId) async {
    if (_incoming.isClosed) return null;
    final raw = call.arguments;
    if (raw is! String) return null;
    try {
      _incoming.add(Envelope.decode(raw));
    } catch (_) {
      // Ignore malformed envelopes — server will time them out.
    }
    return null;
  }

  @override
  Stream<Envelope> get incoming => _incoming.stream;

  @override
  void send(Envelope envelope) {
    // Fire and forget; replies arrive on rpc.recv. Errors are dropped
    // because we have no envelope id to fail-respond against here.
    DesktopMultiWindow.invokeMethod(
      targetWindowId,
      'rpc.send',
      envelope.encode(),
    );
  }

  @override
  Future<void> dispose() async {
    await _incoming.close();
  }
}

// Host-side router: receives `rpc.send` envelopes from subwindows and
// hands them to a dispatcher. The dispatcher is responsible for sending
// replies back via `DesktopMultiWindow.invokeMethod(fromWindowId, ...)`.
class HostWindowRouter {
  HostWindowRouter({required this.dispatch}) {
    WindowRouter.instance.addRoute('rpc.send', _onSend);
  }

  // Receives the decoded envelope and the originating window id; expected
  // to call `_deliver` for each reply envelope, which will route it back
  // to that window.
  final void Function(
    Envelope envelope,
    int fromWindowId,
    void Function(Envelope) reply,
  )
  dispatch;

  Future<dynamic> _onSend(MethodCall call, int fromWindowId) async {
    final raw = call.arguments;
    if (raw is! String) return null;
    try {
      final env = Envelope.decode(raw);
      dispatch(env, fromWindowId, (reply) {
        DesktopMultiWindow.invokeMethod(
          fromWindowId,
          'rpc.recv',
          reply.encode(),
        );
      });
    } catch (_) {
      // Ignore — see IsolateTransport._onRecv.
    }
    return null;
  }
}

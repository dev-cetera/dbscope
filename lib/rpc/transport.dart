// Transport is the only thing that's allowed to know whether the server
// is in this isolate, in another window's isolate, or over a network.
//
// A Transport ships envelopes to a server endpoint and surfaces envelopes
// coming back. Correlation (matching `res` to `req` by id) and ergonomic
// Future/Stream surface live one layer up in BackendClient.

import 'dart:async';

import 'envelope.dart';

abstract class Transport {
  // Stream of envelopes coming back from the server.
  Stream<Envelope> get incoming;

  // Send an envelope to the server.
  void send(Envelope envelope);

  Future<void> dispose();
}

// LocalTransport hands envelopes directly to an in-process handler.
// Used in the host isolate (where the Server runs) and as the fallback
// when multi-window isn't in play.
class LocalTransport implements Transport {
  final void Function(Envelope envelope, void Function(Envelope) reply)
  _handler;
  // Single-subscription: BackendClient is the only listener. Broadcast
  // controllers' done future can fail to complete in the flutter_test
  // zone after a sub has been cancelled, deadlocking the test runner.
  final StreamController<Envelope> _incoming = StreamController<Envelope>();

  LocalTransport(this._handler);

  @override
  Stream<Envelope> get incoming => _incoming.stream;

  @override
  void send(Envelope envelope) {
    // Schedule on a microtask so the caller's await/listener wiring
    // completes before the response arrives. Mirrors what any real
    // transport does anyway (network latency >= 0).
    scheduleMicrotask(() {
      try {
        _handler(envelope, _deliver);
      } catch (e, st) {
        _deliver(
          Envelope.resError(
            envelope.id,
            RpcError('internal', e.toString(), data: st.toString()),
          ),
        );
      }
    });
  }

  void _deliver(Envelope envelope) {
    if (_incoming.isClosed) return;
    _incoming.add(envelope);
  }

  @override
  Future<void> dispose() async {
    await _incoming.close();
  }
}

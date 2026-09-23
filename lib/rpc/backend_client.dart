// BackendClient — typed surface for talking to a Server. Owns id
// assignment, correlation, and lifecycle of pending requests/subs.
// Service clients are thin wrappers that translate domain calls into
// `request`/`subscribe`.

import 'dart:async';

import 'envelope.dart';
import 'transport.dart';

class BackendClient {
  final Transport _transport;
  StreamSubscription<Envelope>? _sub;
  int _seq = 0;
  final Map<String, Completer<Object?>> _pending = {};
  final Map<String, StreamController<Object?>> _streams = {};
  bool _disposed = false;

  BackendClient(this._transport) {
    _sub = _transport.incoming.listen(_handle);
  }

  String _nextId() => 'c${++_seq}';

  void _handle(Envelope env) {
    switch (env.kind) {
      case EnvelopeKind.res:
        final c = _pending.remove(env.id);
        if (c == null) return;
        if (env.error != null) {
          c.completeError(env.error!);
        } else {
          c.complete(env.result);
        }
        break;
      case EnvelopeKind.evt:
        _streams[env.id]?.add(env.result);
        break;
      case EnvelopeKind.end:
        final s = _streams.remove(env.id);
        s?.close();
        break;
      case EnvelopeKind.err:
        final s = _streams.remove(env.id);
        if (s != null) {
          if (env.error != null) {
            s.addError(env.error!);
          }
          s.close();
        }
        break;
      case EnvelopeKind.req:
      case EnvelopeKind.sub:
      case EnvelopeKind.unsub:
        // Server→client requests not used in the current contract.
        break;
    }
  }

  Future<Object?> request(String method, [Object? params]) {
    if (_disposed) {
      return Future.error(const RpcError('disposed', 'client disposed'));
    }
    final id = _nextId();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _transport.send(Envelope.req(id, method, params));
    return completer.future;
  }

  // Returns a Stream of event payloads. Caller cancels the subscription
  // by cancelling the returned stream's listener — we'll send an unsub.
  Stream<Object?> subscribe(String method, [Object? params]) {
    if (_disposed) {
      return Stream.error(const RpcError('disposed', 'client disposed'));
    }
    final id = _nextId();
    late StreamController<Object?> controller;
    controller = StreamController<Object?>(
      onListen: () {
        _streams[id] = controller;
        _transport.send(Envelope.sub(id, method, params));
      },
      onCancel: () async {
        _streams.remove(id);
        if (!_disposed) {
          _transport.send(Envelope.unsub(id));
        }
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const RpcError('disposed', 'client disposed'));
      }
    }
    _pending.clear();
    for (final s in _streams.values) {
      await s.close();
    }
    _streams.clear();
    await _transport.dispose();
  }
}

// Server — owns the canonical app state (profiles, connections, jobs).
// Services register handlers and the Server routes incoming envelopes to
// them. It also publishes events out to subscribers.
//
// The Server is transport-agnostic: it takes envelopes in via `dispatch`
// and emits envelopes via the `out` callback passed at `dispatch` time.
// LocalTransport drives this directly; IsolateTransport's host adapter
// forwards subwindow envelopes to dispatch and ships emitted envelopes
// back over the method channel.

import 'dart:async';

import '../rpc/envelope.dart';

typedef Replier = void Function(Envelope envelope);
typedef RequestHandler = Future<Object?> Function(Object? params);
typedef SubscriptionHandler = Stream<Object?> Function(Object? params);

class Server {
  final Map<String, RequestHandler> _requests = {};
  final Map<String, SubscriptionHandler> _subscriptions = {};
  // active subscriptions, keyed by envelope id, scoped to the replier
  // that opened them. Multiple transports can drive one Server.
  final Map<String, StreamSubscription<Object?>> _subs = {};

  // Register a request/response method.
  void onRequest(String method, RequestHandler handler) {
    _requests[method] = handler;
  }

  // Register a streaming subscription method.
  void onSubscription(String method, SubscriptionHandler handler) {
    _subscriptions[method] = handler;
  }

  // Drive an envelope from a transport. `out` is how the server replies
  // for this caller. Caller is responsible for tying envelope ids to the
  // right Transport when multiple transports share one Server.
  void dispatch(Envelope env, Replier out) {
    switch (env.kind) {
      case EnvelopeKind.req:
        unawaited(_handleRequest(env, out));
      case EnvelopeKind.sub:
        _handleSub(env, out);
      case EnvelopeKind.unsub:
        final subscription = _subs.remove(env.id);
        unawaited(subscription?.cancel());
      case EnvelopeKind.res:
      case EnvelopeKind.evt:
      case EnvelopeKind.end:
      case EnvelopeKind.err:
        // Server only consumes req/sub/unsub.
        break;
    }
  }

  Future<void> _handleRequest(Envelope env, Replier out) async {
    final method = env.method;
    final handler = method == null ? null : _requests[method];
    if (handler == null) {
      out(
        Envelope.resError(
          env.id,
          RpcError('unknown_method', 'no handler for $method'),
        ),
      );
      return;
    }
    try {
      final result = await handler(env.params);
      out(Envelope.res(env.id, result));
    } on RpcError catch (e) {
      out(Envelope.resError(env.id, e));
    } catch (e, st) {
      out(
        Envelope.resError(
          env.id,
          RpcError('handler_error', e.toString(), data: st.toString()),
        ),
      );
    }
  }

  void _handleSub(Envelope env, Replier out) {
    final method = env.method;
    final handler = method == null ? null : _subscriptions[method];
    if (handler == null) {
      out(
        Envelope.err(
          env.id,
          RpcError('unknown_method', 'no subscription for $method'),
        ),
      );
      return;
    }
    final Stream<Object?> stream;
    try {
      stream = handler(env.params);
    } on RpcError catch (e) {
      out(Envelope.err(env.id, e));
      return;
    } catch (e) {
      out(Envelope.err(env.id, RpcError('handler_error', e.toString())));
      return;
    }
    // Kept in `_subs` and cancelled on `unsub` (see `dispatch`).
    // ignore: cancel_subscriptions
    final subscription = stream.listen(
      (data) => out(Envelope.evt(env.id, data)),
      onError: (Object e, StackTrace st) {
        out(
          Envelope.err(
            env.id,
            e is RpcError ? e : RpcError('handler_error', e.toString(), data: st.toString()),
          ),
        );
        _subs.remove(env.id);
      },
      onDone: () {
        out(Envelope.end(env.id));
        _subs.remove(env.id);
      },
    );
    _subs[env.id] = subscription;
  }

  Future<void> dispose() async {
    for (final subscription in _subs.values) {
      await subscription.cancel();
    }
    _subs.clear();
  }
}

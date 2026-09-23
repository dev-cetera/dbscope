// BusService — pub/sub across services. Other server-side code publishes
// to topics; clients subscribe via `bus.subscribe` and receive event
// payloads as `{topic, data}`.
//
// Topics are flat strings. Conventions:
// profile.changed -> {profiles: [...]}
// connection.state:<profileId> -> {state: 'connected'|'disconnected'|'connecting'|'error', error?}
// schema.invalidated:<profileId> -> {schema?, table?}
// job.created -> {id, kind, ...}
// job.progress:<jobId> -> {phase, processed, total?}
// job.finished:<jobId> -> {ok, summary}
//
// Wildcard subscriptions: a subscriber may pass `topic: 'job.*'` to match
// any topic starting with `job.`. Otherwise it's an exact match.

import 'dart:async';

import '../server.dart';

class BusService {
  final StreamController<_BusEvent> _events = StreamController.broadcast();

  void register(Server server) {
    server.onSubscription('bus.subscribe', _subscribe);
  }

  Stream<Object?> _subscribe(Object? params) {
    final p = params is Map<String, Object?>
        ? params
        : const <String, Object?>{};
    final topic = p['topic'] as String? ?? '*';
    final matcher = _matcherFor(topic);
    return _events.stream
        .where((e) => matcher(e.topic))
        .map<Object?>((e) => {'topic': e.topic, 'data': e.data});
  }

  void publish(String topic, Object? data) {
    if (_disposed || _events.isClosed) return;
    _events.add(_BusEvent(topic, data));
  }

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Intentionally don't await _events.close: broadcast controllers'
    // done future can fail to complete in the flutter_test zone (the
    // ignored Future blocks the test runner's pending-future tracker
    // even though we don't await it), and we don't actually need the
    // close to complete — once references to BusService drop the
    // controller is GC'd.
  }

  bool Function(String topic) _matcherFor(String pattern) {
    if (pattern == '*') return (_) => true;
    if (pattern.endsWith('.*')) {
      final prefix = pattern.substring(0, pattern.length - 1); // keep dot
      return (t) => t.startsWith(prefix);
    }
    return (t) => t == pattern;
  }
}

class _BusEvent {
  final String topic;
  final Object? data;
  _BusEvent(this.topic, this.data);
}

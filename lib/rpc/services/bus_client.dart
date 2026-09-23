// BusClient — typed wrapper around `bus.subscribe`. UI code subscribes
// to topic patterns (e.g. 'profile.changed', 'job.progress:abc', 'job.*')
// and gets a Stream of BusEvent.

import 'dart:async';

import '../backend_client.dart';

class BusEvent {
  final String topic;
  final Object? data;
  const BusEvent(this.topic, this.data);

  Map<String, Object?>? get dataAsMap =>
      data is Map<String, Object?> ? data as Map<String, Object?> : null;
}

class BusClient {
  final BackendClient _client;
  BusClient(this._client);

  Stream<BusEvent> subscribe(String topic) {
    return _client.subscribe('bus.subscribe', {'topic': topic}).map((payload) {
      if (payload is Map<String, Object?>) {
        return BusEvent(payload['topic'] as String, payload['data']);
      }
      return const BusEvent('', null);
    });
  }
}

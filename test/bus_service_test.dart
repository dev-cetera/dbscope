// BusService is the cross-service pub/sub. The matching contract is small
// but UI-visible: '*' matches every topic, 'foo.*' matches by prefix
// (including the dot), and an exact string matches exactly that topic.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/rpc/envelope.dart';
import 'package:dbscope/server/server.dart';
import 'package:dbscope/server/services/bus_service.dart';

Future<List<Object?>> _collectFromSubscribe(
  Server server,
  Object? params,
  void Function() act,
) async {
  final replies = <Envelope>[];
  server.dispatch(
    Envelope.sub('sub', 'bus.subscribe', params),
    replies.add,
  );
  // Let the subscription register before publishing.
  await Future<void>.delayed(Duration.zero);
  act();
  await Future<void>.delayed(Duration.zero);
  return replies
      .where((e) => e.kind == EnvelopeKind.evt)
      .map((e) => e.result)
      .toList();
}

void main() {
  group('BusService topic matching', () {
    test(
      'subscriber with no topic uses default "*" and gets every event',
      () async {
        final server = Server();
        final bus = BusService()..register(server);

        final events = await _collectFromSubscribe(server, null, () {
          bus.publish('job.created', {'id': '1'});
          bus.publish('connection.state:p1', {'state': 'connected'});
        });

        expect(events, hasLength(2));
      },
    );

    test('topic="*" matches every event', () async {
      final server = Server();
      final bus = BusService()..register(server);

      final events = await _collectFromSubscribe(
        server,
        {'topic': '*'},
        () {
          bus.publish('a', 1);
          bus.publish('b', 2);
        },
      );

      expect(events, hasLength(2));
    });

    test('prefix glob "job.*" matches only job.* topics', () async {
      final server = Server();
      final bus = BusService()..register(server);

      final events = await _collectFromSubscribe(
        server,
        {'topic': 'job.*'},
        () {
          bus.publish('job.created', {'id': '1'});
          bus.publish('job.progress:abc', {'phase': 'running'});
          bus.publish('connection.state:p1', {'state': 'connected'});
        },
      );

      expect(events, hasLength(2));
      final topics = events
          .map((e) => (e as Map<String, Object?>)['topic'])
          .toList();
      expect(topics, ['job.created', 'job.progress:abc']);
    });

    test('exact topic matches only that exact topic', () async {
      final server = Server();
      final bus = BusService()..register(server);

      final events = await _collectFromSubscribe(
        server,
        {'topic': 'profile.changed'},
        () {
          bus.publish('profile.changed', {'profiles': []});
          bus.publish('profile.added', {'id': 'x'});
          bus.publish('profile', {});
        },
      );

      expect(events, hasLength(1));
      final payload = events.single as Map<String, Object?>;
      expect(payload['topic'], 'profile.changed');
      expect(payload['data'], {'profiles': []});
    });

    test(
      'publish after dispose() is a silent no-op (does not throw)',
      () async {
        final server = Server();
        final bus = BusService()..register(server);

        await bus.dispose();
        expect(() => bus.publish('anything', 1), returnsNormally);
      },
    );

    test('event payload shape is {topic, data}', () async {
      final server = Server();
      final bus = BusService()..register(server);

      final events = await _collectFromSubscribe(
        server,
        {'topic': '*'},
        () => bus.publish('x.y', 'value'),
      );

      expect(events.single, {'topic': 'x.y', 'data': 'value'});
    });
  });
}

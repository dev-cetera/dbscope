// Server is the RPC kernel — every cross-window call lands in dispatch().
// The contract worth pinning down:
// * req → handler → res envelope with matching id.
// * Unknown methods return a res with an `unknown_method` RpcError.
// * Handler exceptions surface as `handler_error` (or RpcError
// verbatim) without crashing the server.
// * sub registers a stream; subsequent events arrive on evt; unsub
// cancels the underlying StreamSubscription.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/rpc/envelope.dart';
import 'package:dbscope/server/server.dart';

void main() {
  group('Server.dispatch — request/response', () {
    test('routes req to registered handler and returns res envelope', () async {
      final server = Server();
      server.onRequest('ping', (params) async => {'pong': params});

      final replies = <Envelope>[];
      server.dispatch(
        Envelope.req('id-1', 'ping', {'msg': 'hi'}),
        replies.add,
      );

      // Handler is async; let the microtask queue flush.
      await Future<void>.delayed(Duration.zero);

      expect(replies, hasLength(1));
      final reply = replies.single;
      expect(reply.id, 'id-1');
      expect(reply.kind, EnvelopeKind.res);
      expect(reply.result, {
        'pong': {'msg': 'hi'},
      });
      expect(reply.error, isNull);
    });

    test('unknown method replies with unknown_method RpcError', () async {
      final server = Server();
      final replies = <Envelope>[];
      server.dispatch(
        Envelope.req('id-2', 'nope', null),
        replies.add,
      );

      await Future<void>.delayed(Duration.zero);
      final reply = replies.single;
      expect(reply.kind, EnvelopeKind.res);
      expect(reply.error?.code, 'unknown_method');
    });

    test('handler that throws RpcError propagates it verbatim', () async {
      final server = Server();
      server.onRequest(
        'boom',
        (_) async => throw const RpcError('not_found', 'no row'),
      );

      final replies = <Envelope>[];
      server.dispatch(
        Envelope.req('id-3', 'boom', null),
        replies.add,
      );

      await Future<void>.delayed(Duration.zero);
      expect(replies.single.error?.code, 'not_found');
      expect(replies.single.error?.message, 'no row');
    });

    test('handler that throws a generic error returns handler_error', () async {
      final server = Server();
      server.onRequest('crash', (_) async => throw StateError('bad state'));

      final replies = <Envelope>[];
      server.dispatch(
        Envelope.req('id-4', 'crash', null),
        replies.add,
      );

      await Future<void>.delayed(Duration.zero);
      expect(replies.single.error?.code, 'handler_error');
      expect(replies.single.error?.message, contains('bad state'));
    });
  });

  group('Server.dispatch — subscriptions', () {
    test(
      'sub delivers stream events as evt envelopes with the same id',
      () async {
        final server = Server();
        final controller = StreamController<Object?>();
        server.onSubscription('events', (_) => controller.stream);

        final replies = <Envelope>[];
        server.dispatch(Envelope.sub('s-1', 'events', null), replies.add);

        controller.add('first');
        controller.add('second');
        await Future<void>.delayed(Duration.zero);

        expect(replies, hasLength(2));
        expect(replies.every((e) => e.id == 's-1'), isTrue);
        expect(replies.every((e) => e.kind == EnvelopeKind.evt), isTrue);
        expect(replies.map((e) => e.result).toList(), ['first', 'second']);

        await controller.close();
      },
    );

    test('stream done emits an `end` envelope', () async {
      final server = Server();
      final controller = StreamController<Object?>();
      server.onSubscription('events', (_) => controller.stream);

      final replies = <Envelope>[];
      server.dispatch(Envelope.sub('s-2', 'events', null), replies.add);
      await controller.close();
      await Future<void>.delayed(Duration.zero);

      expect(replies.last.kind, EnvelopeKind.end);
      expect(replies.last.id, 's-2');
    });

    test(
      'stream error emits an `err` envelope and stops further events',
      () async {
        final server = Server();
        final controller = StreamController<Object?>();
        server.onSubscription('events', (_) => controller.stream);

        final replies = <Envelope>[];
        server.dispatch(Envelope.sub('s-3', 'events', null), replies.add);

        controller.addError(StateError('boom'));
        await Future<void>.delayed(Duration.zero);

        final err = replies.singleWhere((e) => e.kind == EnvelopeKind.err);
        expect(err.error?.code, 'handler_error');

        await controller.close();
      },
    );

    test('unsub cancels the underlying stream subscription', () async {
      final server = Server();
      var cancelCalled = false;
      final controller = StreamController<Object?>(
        onCancel: () => cancelCalled = true,
      );
      server.onSubscription('events', (_) => controller.stream);

      final replies = <Envelope>[];
      server.dispatch(Envelope.sub('s-4', 'events', null), replies.add);
      controller.add('x');
      await Future<void>.delayed(Duration.zero);

      server.dispatch(Envelope.unsub('s-4'), replies.add);
      await Future<void>.delayed(Duration.zero);

      expect(cancelCalled, isTrue);
      // Events posted after unsub should not reach the replier.
      final countBefore = replies.length;
      controller.add('after-unsub');
      await Future<void>.delayed(Duration.zero);
      expect(replies.length, countBefore);

      await controller.close();
    });

    test(
      'subscription to unknown method emits err with unknown_method',
      () async {
        final server = Server();
        final replies = <Envelope>[];
        server.dispatch(Envelope.sub('s-5', 'no-such', null), replies.add);

        expect(replies, hasLength(1));
        expect(replies.single.kind, EnvelopeKind.err);
        expect(replies.single.error?.code, 'unknown_method');
      },
    );
  });
}

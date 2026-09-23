// Tests for the RPC Envelope wire format. Every cross-isolate message
// goes through this encoding, so a regression here silently breaks every
// subwindow. Round-trip each kind through JSON and check the discriminator
// stays stable.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/rpc/envelope.dart';

void main() {
  group('EnvelopeKind.parse', () {
    test('parses every defined wire string', () {
      expect(EnvelopeKind.parse('req'), EnvelopeKind.req);
      expect(EnvelopeKind.parse('res'), EnvelopeKind.res);
      expect(EnvelopeKind.parse('sub'), EnvelopeKind.sub);
      expect(EnvelopeKind.parse('unsub'), EnvelopeKind.unsub);
      expect(EnvelopeKind.parse('evt'), EnvelopeKind.evt);
      expect(EnvelopeKind.parse('end'), EnvelopeKind.end);
      expect(EnvelopeKind.parse('err'), EnvelopeKind.err);
    });

    test('throws on unknown kind', () {
      expect(
        () => EnvelopeKind.parse('bogus'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('RpcError', () {
    test('toJson/fromJson roundtrip preserves all fields', () {
      const error = RpcError('not_found', 'no such row', data: {'id': 'x'});
      final roundTrip = RpcError.fromJson(error.toJson());
      expect(roundTrip.code, 'not_found');
      expect(roundTrip.message, 'no such row');
      expect(roundTrip.data, {'id': 'x'});
    });

    test('toJson omits null data', () {
      const error = RpcError('e', 'm');
      expect(error.toJson().containsKey('data'), isFalse);
    });

    test('fromJson tolerates missing fields with defaults', () {
      final error = RpcError.fromJson(const <String, Object?>{});
      expect(error.code, 'unknown');
      expect(error.message, '');
      expect(error.data, isNull);
    });
  });

  group('Envelope', () {
    test('req encode/decode roundtrip', () {
      final env = Envelope.req('id-1', 'ping', {'x': 1});
      final decoded = Envelope.decode(env.encode());
      expect(decoded.id, 'id-1');
      expect(decoded.kind, EnvelopeKind.req);
      expect(decoded.method, 'ping');
      expect(decoded.params, {'x': 1});
      expect(decoded.v, kProtocolVersion);
    });

    test('res encode/decode roundtrip', () {
      final env = Envelope.res('id-2', {'ok': true});
      final decoded = Envelope.decode(env.encode());
      expect(decoded.id, 'id-2');
      expect(decoded.kind, EnvelopeKind.res);
      expect(decoded.result, {'ok': true});
      expect(decoded.error, isNull);
    });

    test('resError encodes error and no result', () {
      final env = Envelope.resError(
        'id-3',
        const RpcError('bad', 'nope', data: 'detail'),
      );
      final json = env.toJson();
      expect(json['kind'], 'res');
      expect(json.containsKey('result'), isFalse);
      expect(json['error'], isA<Map<String, Object?>>());

      final decoded = Envelope.decode(env.encode());
      expect(decoded.error?.code, 'bad');
      expect(decoded.error?.message, 'nope');
      expect(decoded.error?.data, 'detail');
    });

    test('sub roundtrip carries method and params', () {
      final env = Envelope.sub('id-4', 'bus.subscribe', {'topic': 'job.*'});
      final decoded = Envelope.decode(env.encode());
      expect(decoded.kind, EnvelopeKind.sub);
      expect(decoded.method, 'bus.subscribe');
      expect(decoded.params, {'topic': 'job.*'});
    });

    test('unsub has only id and kind', () {
      final env = Envelope.unsub('id-5');
      final json = env.toJson();
      expect(json['kind'], 'unsub');
      expect(json.containsKey('method'), isFalse);
      expect(json.containsKey('params'), isFalse);
      expect(json.containsKey('result'), isFalse);
      expect(json.containsKey('error'), isFalse);
    });

    test('evt carries payload as result', () {
      final env = Envelope.evt('id-6', {'topic': 't', 'data': 42});
      final decoded = Envelope.decode(env.encode());
      expect(decoded.kind, EnvelopeKind.evt);
      expect(decoded.result, {'topic': 't', 'data': 42});
    });

    test('end has only id and kind', () {
      final env = Envelope.end('id-7');
      final decoded = Envelope.decode(env.encode());
      expect(decoded.kind, EnvelopeKind.end);
      expect(decoded.result, isNull);
      expect(decoded.error, isNull);
    });

    test('err carries an RpcError', () {
      final env = Envelope.err('id-8', const RpcError('boom', 'kaboom'));
      final decoded = Envelope.decode(env.encode());
      expect(decoded.kind, EnvelopeKind.err);
      expect(decoded.error?.code, 'boom');
      expect(decoded.error?.message, 'kaboom');
    });

    test('protocol version defaults and survives roundtrip', () {
      final env = Envelope.req('id-9', 'm', null);
      expect(env.v, kProtocolVersion);
      final decoded = Envelope.decode(env.encode());
      expect(decoded.v, kProtocolVersion);
    });

    test('fromJson tolerates missing v with default', () {
      final decoded = Envelope.fromJson(<String, Object?>{
        'id': 'x',
        'kind': 'req',
        'method': 'm',
      });
      expect(decoded.v, kProtocolVersion);
    });
  });
}

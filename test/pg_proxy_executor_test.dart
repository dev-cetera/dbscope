// Contract: PgProxyExecutor talks to dbscope_pg_proxy over a WebSocket.
// * If the socket closes before the proxy says `ready`, open() fails right
//   away with a "closed" error instead of waiting out the ready timeout.
// * Result columns arrive as `typeOid`; the executor shows the Postgres
//   type name for it (`int4`), not the driver's `Type(oid:23)` spelling.
// * A RowCap travels in the `execute` message and `truncated` comes back on
//   the result.
// * Cancelling a token sends `cancel` for that statement's id, and the caller
//   gets an empty result. A token already cancelled sends nothing at all.
// Uses a throwaway WebSocket server on localhost, no database.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope_pg_proxy_plugin/src/executor.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HttpServer> _serve(void Function(WebSocket socket) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.transform(WebSocketTransformer()).listen(onSocket);
  return server;
}

ConnectionProfile _profile(HttpServer server) => ConnectionProfile(
  name: 'proxy',
  kind: 'pg_proxy',
  extra: {'proxyUrl': 'ws://127.0.0.1:${server.port}'},
);

void main() {
  test('open fails promptly when the socket closes before ready', () async {
    final server = await _serve((socket) => socket.close());
    addTearDown(() => server.close(force: true));
    await expectLater(
      PgProxyExecutor.open(_profile(server)).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<PgProxyException>().having((e) => e.message, 'message', contains('closed')),
      ),
    );
  });

  test('result columns carry the Postgres type name for their oid', () async {
    final server = await _serve((socket) {
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, Object?>;
        if (message['type'] == 'open') {
          socket.add(jsonEncode({'type': 'ready'}));
        } else if (message['type'] == 'execute') {
          socket.add(
            jsonEncode({
              'type': 'result',
              'id': message['id'],
              'columns': [
                {'name': 'n', 'typeOid': 23},
              ],
              'rows': [
                [1],
              ],
              'affected': 0,
            }),
          );
        }
      });
    });
    addTearDown(() => server.close(force: true));
    final executor = await PgProxyExecutor.open(_profile(server));
    addTearDown(() => executor.close(force: true));
    final result = await executor.execute('select 1');
    expect(result.columns.single.typeName, 'int4');
  });

  group('row cap and cancel', () {
    /// A proxy stand-in that calls [onMessage] for every message after `open`.
    Future<PgProxyExecutor> open(
      void Function(WebSocket socket, Map<String, Object?> message) onMessage,
    ) async {
      final server = await _serve((socket) {
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, Object?>;
          if (message['type'] == 'open') {
            socket.add(jsonEncode({'type': 'ready'}));
          } else {
            onMessage(socket, message);
          }
        });
      });
      addTearDown(() => server.close(force: true));
      final executor = await PgProxyExecutor.open(_profile(server));
      addTearDown(() => executor.close(force: true));
      return executor;
    }

    test('the cap is sent and truncated comes back', () async {
      Map<String, Object?>? sent;
      final executor = await open((socket, message) {
        sent = message;
        socket.add(
          jsonEncode({'type': 'result', 'id': message['id'], 'columns': <Object>[], 'rows': <Object>[], 'truncated': true}),
        );
      });
      final result = await executor.execute(
        'select 1',
        rowCap: const RowCap(10, mode: RowCapMode.stopAtLimit),
      );
      expect(sent?['maxRows'], 10);
      expect(sent?['rowCapMode'], 'stopAtLimit');
      expect(result.truncated, isTrue);
    });

    test('cancelling sends cancel for the running statement', () async {
      final messages = <Map<String, Object?>>[];
      final cancelSeen = Completer<void>();
      final executor = await open((socket, message) {
        messages.add(message);
        if (message['type'] == 'cancel') {
          socket.add(
            jsonEncode({'type': 'result', 'id': message['id'], 'columns': <Object>[], 'rows': <Object>[], 'cancelled': true}),
          );
          cancelSeen.complete();
        }
      });
      final token = CancelToken();
      final running = executor.execute('select pg_sleep(60)', cancelToken: token);
      token.cancel();
      final result = await running;
      await cancelSeen.future;
      expect(result.rows, isEmpty);
      expect(messages.last['type'], 'cancel');
      expect(messages.last['id'], messages.first['id']);
    });

    test('a token already cancelled sends nothing', () async {
      final messages = <Map<String, Object?>>[];
      final executor = await open((socket, message) => messages.add(message));
      final result = await executor.execute('delete from t', cancelToken: CancelToken()..cancel());
      expect(result.rows, isEmpty);
      expect(messages, isEmpty);
    });
  });
}

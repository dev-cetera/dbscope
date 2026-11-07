// Contract: PgProxyExecutor talks to dbscope_pg_proxy over a WebSocket.
// * If the socket closes before the proxy says `ready`, open() fails right
//   away with a "closed" error instead of waiting out the ready timeout.
// * Result columns arrive as `typeOid`; the executor shows the Postgres
//   type name for it (`int4`), not the driver's `Type(oid:23)` spelling.
// Uses a throwaway WebSocket server on localhost, no database.

import 'dart:convert';
import 'dart:io';

import 'package:dbscope/connection/profile.dart';
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
}

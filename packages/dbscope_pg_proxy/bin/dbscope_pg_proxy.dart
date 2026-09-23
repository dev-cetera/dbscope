// dbscope_pg_proxy — minimal WebSocket → Postgres proxy.
//
// Run:
// dart run packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart \
// --port 8765 \
// [--shared-secret SECRET] \
// [--allow-origin https://your.web.host]
//
// Wire protocol is JSON envelopes over a single WebSocket. One WebSocket
// owns one Postgres connection for its lifetime.
//
// client → server:
// { "type": "open", "host": "...", "port": 5432, "database": "...",
// "username": "...", "password": "...", "sslMode": "require",
// "secret": "..." }
// { "type": "execute", "id": "<uuid>", "sql": "...",
// "positional": [...] | "named": {...} }
// { "type": "close" }
//
// server → client:
// { "type": "ready" }
// { "type": "result", "id": "...", "columns": [{name, typeName}],
// "rows": [[...]], "affected": 0 }
// { "type": "error", "id"?: "...", "code"?: "...", "message": "...",
// "constraintName"?: "..." }
//
// Security: the proxy is a thin pipe to a database — anyone who can
// reach it can submit any SQL the configured Postgres user can run.
// Always: (a) bind to a trusted interface, (b) put it behind TLS
// (reverse proxy → wss://), and (c) set --shared-secret so clients
// must echo it on `open`. Pair this with a least-privileged Postgres
// role.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final server = await HttpServer.bind(opts.host, opts.port);
  stdout.writeln(
    'dbscope_pg_proxy listening on ws://${opts.host}:${opts.port}',
  );
  if (opts.sharedSecret != null) {
    stdout.writeln('shared-secret authentication required');
  }
  if (opts.allowOrigin != null) {
    stdout.writeln('restricting Origin to: ${opts.allowOrigin}');
  }
  await for (final req in server) {
    if (req.uri.path == '/health') {
      req.response
        ..statusCode = 200
        ..write('ok');
      await req.response.close();
      continue;
    }
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = 426
        ..headers.set('upgrade', 'websocket')
        ..write('websocket required');
      await req.response.close();
      continue;
    }
    if (opts.allowOrigin != null) {
      final origin = req.headers.value('origin');
      if (origin != opts.allowOrigin) {
        req.response
          ..statusCode = 403
          ..write('forbidden origin');
        await req.response.close();
        continue;
      }
    }
    unawaited(_handleUpgrade(req, opts));
  }
}

Future<void> _handleUpgrade(HttpRequest req, _Opts opts) async {
  final socket = await WebSocketTransformer.upgrade(req);
  await _Session(socket, opts).run();
}

class _Session {
  final WebSocket socket;
  final _Opts opts;
  pg.Connection? _conn;

  _Session(this.socket, this.opts);

  Future<void> run() async {
    try {
      await for (final raw in socket) {
        if (raw is! String) {
          await _send({'type': 'error', 'message': 'expected JSON text frame'});
          continue;
        }
        Map<String, Object?> msg;
        try {
          msg = jsonDecode(raw) as Map<String, Object?>;
        } catch (e) {
          await _send({'type': 'error', 'message': 'invalid JSON: $e'});
          continue;
        }
        final type = msg['type'];
        switch (type) {
          case 'open':
            await _onOpen(msg);
          case 'execute':
            await _onExecute(msg);
          case 'close':
            return;
          default:
            await _send({'type': 'error', 'message': 'unknown type "$type"'});
        }
      }
    } finally {
      try {
        await _conn?.close();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> _onOpen(Map<String, Object?> msg) async {
    if (opts.sharedSecret != null) {
      final got = msg['secret'];
      if (got != opts.sharedSecret) {
        await _send({'type': 'error', 'message': 'bad shared-secret'});
        await socket.close();
        return;
      }
    }
    if (_conn != null) {
      await _send({'type': 'error', 'message': 'already opened'});
      return;
    }
    final host = msg['host'] as String? ?? '';
    final port = (msg['port'] as num?)?.toInt() ?? 5432;
    final db = msg['database'] as String? ?? '';
    final user = msg['username'] as String? ?? '';
    final pass = msg['password'] as String? ?? '';
    final sslRaw = (msg['sslMode'] as String? ?? 'require').toLowerCase();
    final ssl = switch (sslRaw) {
      'disable' => pg.SslMode.disable,
      'require' => pg.SslMode.require,
      'verifyfull' || 'verify-full' || 'verify_full' => pg.SslMode.verifyFull,
      _ => pg.SslMode.require,
    };
    try {
      final endpoint = pg.Endpoint(
        host: host,
        port: port,
        database: db,
        username: user,
        password: pass,
      );
      const timeout = Duration(seconds: 15);

      // Two-step open: package:postgres only takes a TypeRegistry at
      // construction time, but enum OIDs aren't known until we query
      // pg_catalog. Discover them on a short-lived connection so the real
      // connection decodes enum values as their label String instead of
      // returning UndecodedBytes (which would serialize as the proxy's
      // generic "Instance of 'UndecodedBytes'" string).
      final discovery = await pg.Connection.open(
        endpoint,
        settings: pg.ConnectionSettings(sslMode: ssl, connectTimeout: timeout),
      );
      final Map<int, pg.Codec> enumCodecs;
      try {
        enumCodecs = await _loadEnumCodecs(discovery);
      } finally {
        try {
          await discovery.close();
        } catch (_) {}
      }

      _conn = await pg.Connection.open(
        endpoint,
        settings: pg.ConnectionSettings(
          sslMode: ssl,
          connectTimeout: timeout,
          typeRegistry: enumCodecs.isEmpty
              ? null
              : pg.TypeRegistry(codecs: enumCodecs),
        ),
      );
      await _send({'type': 'ready'});
    } catch (e) {
      await _send({'type': 'error', 'message': 'open failed: $e'});
      await socket.close();
    }
  }

  Future<void> _onExecute(Map<String, Object?> msg) async {
    final conn = _conn;
    final id = msg['id'] as String?;
    if (conn == null) {
      await _send({
        'type': 'error',
        'id': id,
        'message': 'connection not open',
      });
      return;
    }
    final sql = msg['sql'] as String? ?? '';
    final positional = msg['positional'];
    final named = msg['named'];
    try {
      final pg.Result result;
      if (named is Map) {
        result = await conn.execute(
          pg.Sql.named(sql),
          parameters: named.map((k, v) => MapEntry(k.toString(), v)),
        );
      } else if (positional is List) {
        result = await conn.execute(pg.Sql(sql), parameters: positional);
      } else {
        result = await conn.execute(sql);
      }
      await _send({
        'type': 'result',
        'id': id,
        'columns': [
          for (final c in result.schema.columns)
            {
              'name': c.columnName ?? '',
              'typeName': c.type.toString().split('.').last,
            },
        ],
        'rows': [
          for (final row in result) [for (final v in row) _serialize(v)],
        ],
        'affected': result.affectedRows,
      });
    } catch (e) {
      String? code;
      String? constraint;
      try {
        final dyn = e as dynamic;
        final c = dyn.code;
        if (c is String) code = c;
      } catch (_) {}
      try {
        final dyn = e as dynamic;
        final n = dyn.constraintName;
        if (n is String) constraint = n;
      } catch (_) {}
      await _send({
        'type': 'error',
        'id': id,
        'code': ?code,
        'constraintName': ?constraint,
        'message': e.toString(),
      });
    }
  }

  Object? _serialize(Object? v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is pg.UndecodedBytes) return _decodeUndecodedBytes(v);
    if (v is List<int>) {
      // Bytes — base64-encode with a discriminator.
      return {'_b64': base64Encode(v)};
    }
    if (v is List) {
      return [for (final e in v) _serialize(e)];
    }
    if (v is Map) {
      return {
        for (final entry in v.entries)
          entry.key.toString: _serialize(entry.value),
      };
    }
    return v.toString();
  }

  // Mirror of PostgresExecutor._decodeValue. `package:postgres` returns
  // UndecodedBytes for any OID it doesn't have a codec for (custom domains,
  // citext, …); the binary protocol bytes are still UTF-8 for text-like
  // types. Only actual bytea (OID 17) gets the `\xDEADBEEF` hex preview.
  static const int _byteaOid = 17;
  Object? _decodeUndecodedBytes(pg.UndecodedBytes v) {
    if (v.typeOid != _byteaOid) {
      try {
        return v.asString;
      } catch (_) {
        // fall through to hex
      }
    }
    final sb = StringBuffer(r'\x');
    for (final byte in v.bytes) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Future<void> _send(Map<String, Object?> msg) async {
    socket.add(jsonEncode(msg));
  }
}

class _Opts {
  final String host;
  final int port;
  final String? sharedSecret;
  final String? allowOrigin;
  _Opts({
    required this.host,
    required this.port,
    required this.sharedSecret,
    required this.allowOrigin,
  });
}

_Opts _parseArgs(List<String> args) {
  String host = '127.0.0.1';
  int port = 8765;
  String? secret;
  String? allow;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) {
        throw ArgumentError('$a needs a value');
      }
      return args[++i];
    }

    switch (a) {
      case '--host':
        host = next();
      case '--port':
        port = int.parse(next());
      case '--shared-secret':
        secret = next();
      case '--allow-origin':
        allow = next();
      case '--help' || '-h':
        _printHelp();
        exit(0);
      default:
        stderr.writeln('unknown arg: $a');
        _printHelp();
        exit(2);
    }
  }
  return _Opts(
    host: host,
    port: port,
    sharedSecret: secret,
    allowOrigin: allow,
  );
}

void _printHelp() {
  stdout.writeln('''
dbscope_pg_proxy — WebSocket → Postgres proxy

Usage:
 dart run packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart [options]

Options:
 --host HOST Interface to bind (default 127.0.0.1)
 --port PORT TCP port (default 8765)
 --shared-secret SECRET Require this in every `open` message
 --allow-origin ORIGIN Require this Origin header (CORS-style hardening)
 -h, --help Show this message
''');
}

Future<Map<int, pg.Codec>> _loadEnumCodecs(pg.Connection conn) async {
  final result = await conn.execute(
    "SELECT oid FROM pg_type WHERE typtype = 'e'",
  );
  final out = <int, pg.Codec>{};
  for (final row in result) {
    final oid = row[0];
    if (oid is int) out[oid] = _EnumCodec();
  }
  return out;
}

/// Codec for user-defined enum types. Wire bytes are the UTF-8 label in
/// both text and binary formats, so one decode covers both.
class _EnumCodec extends pg.Codec {
  _EnumCodec();

  @override
  pg.EncodedValue? encode(pg.TypedValue input, pg.CodecContext context) {
    final v = input.value;
    if (v == null) return null;
    final bytes = Uint8List.fromList(context.encoding.encode(v.toString()));
    return pg.EncodedValue.text(bytes);
  }

  @override
  Object? decode(pg.EncodedValue input, pg.CodecContext context) {
    final bytes = input.bytes;
    if (bytes == null) return null;
    return context.encoding.decode(bytes);
  }
}

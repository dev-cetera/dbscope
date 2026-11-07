// dbscope_pg_proxy — minimal WebSocket → Postgres proxy.
//
// Run:
// dart run packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart \
// --port 8765 \
// [--shared-secret SECRET] \
// [--allow-origin https://your.web.host] (repeatable)
//
// Wire protocol is JSON envelopes over a single WebSocket. One WebSocket
// owns one Postgres connection for its lifetime.
//
// client → server:
// { "type": "open", "host": "...", "port": 5432, "database": "...",
// "username": "...", "password": "...", "sslMode": "require",
// "secret": "..." }
// { "type": "execute", "id": "<uuid>", "sql": "...",
// "positional": [...] | "named": {...}, "maxRows"?: 10000,
// "rowCapMode"?: "readAndDrop" }
// { "type": "cancel", "id": "<uuid of a running execute>" }
// { "type": "close" }
//
// server → client:
// { "type": "ready" }
// { "type": "result", "id": "...", "columns": [{name, typeOid}],
// "rows": [[...]], "affected": 0, "truncated"?: true, "cancelled"?: true }
// { "type": "error", "id"?: "...", "code"?: "...", "message": "...",
// "constraintName"?: "..." }
//
// Security: the proxy is a thin pipe to a database — anyone who can
// reach it can submit any SQL the configured Postgres user can run.
// Always: (a) bind to a trusted interface, (b) put it behind TLS
// (reverse proxy → wss://), and (c) set --shared-secret so clients
// must echo it on `open`. Pair this with a least-privileged Postgres
// role.
//
// Browsers let any web page open a WebSocket to 127.0.0.1, so by default
// the proxy only accepts upgrades whose Origin is the hosted dbscope web
// app or a localhost page (see `_kDefaultOrigins`), or exactly the
// `--allow-origin` list when one is given. Clients that send no
// Origin (scripts, curl) are not browsers and are let through.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbscope_pg_core/dbscope_pg_core.dart';
import 'package:postgres/postgres.dart' as pg;

/// Statements one client may have running or queued. They used to be bounded
/// by reading one message at a time; now each holds memory until it ends.
const _kMaxInFlightStatements = 64;

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final server = await HttpServer.bind(opts.host, opts.port);
  stdout.writeln(
    'dbscope_pg_proxy listening on ws://${opts.host}:${opts.port}',
  );
  if (opts.sharedSecret != null) {
    stdout.writeln('shared-secret authentication required');
  }
  if (opts.allowAnyOrigin) {
    stdout.writeln('WARNING: accepting WebSocket upgrades from any Origin');
  } else if (opts.allowOrigins.isNotEmpty) {
    stdout.writeln('accepting Origin: ${opts.allowOrigins.join(', ')}');
  } else {
    stdout.writeln('accepting Origin: ${_kDefaultOrigins.join(', ')} and localhost pages');
  }
  await for (final req in server) {
    try {
      await _route(req, opts);
    } catch (e) {
      // One bad request (a client that hung up mid-response, …) must not
      // stop the accept loop for everyone else.
      stderr.writeln('request failed: $e');
    }
  }
}

Future<void> _route(HttpRequest req, _Opts opts) async {
  if (req.uri.path == '/health') {
    req.response
      ..statusCode = 200
      ..write('ok');
    await req.response.close();
    return;
  }
  if (!WebSocketTransformer.isUpgradeRequest(req)) {
    req.response
      ..statusCode = 426
      ..headers.set('upgrade', 'websocket')
      ..write('websocket required');
    await req.response.close();
    return;
  }
  final origin = req.headers.value('origin');
  if (!_originAllowed(origin, opts)) {
    stderr.writeln('rejected WebSocket upgrade from Origin $origin');
    req.response
      ..statusCode = 403
      ..write('forbidden origin');
    await req.response.close();
    return;
  }
  // A vanished client's socket reports its reset on futures nobody is awaiting
  // while statements run concurrently. Uncaught, that would kill the whole
  // proxy and every other client's session with it.
  runZonedGuarded(
    () => unawaited(_handleUpgrade(req, opts)),
    (error, _) => stderr.writeln('session error: $error'),
  );
}

/// Origins accepted when no `--allow-origin` is given: the hosted web app
/// (plus any localhost page, see [_originAllowed]).
const _kDefaultOrigins = {
  'https://dbscope-prod.web.app',
  'https://dbscope-prod.firebaseapp.com',
};

bool _originAllowed(String? origin, _Opts opts) {
  if (opts.allowAnyOrigin || origin == null) return true;
  // An explicit list replaces the defaults, so it can only narrow them.
  if (opts.allowOrigins.isNotEmpty) return opts.allowOrigins.contains(origin);
  if (_kDefaultOrigins.contains(origin)) return true;
  final uri = Uri.tryParse(origin);
  // A locally served web build (`flutter run -d chrome`, a static server).
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1');
}

/// Drops sockets whose peer vanished without closing (laptop asleep, network
/// gone), so their database connections don't pile up.
const _kPingInterval = Duration(seconds: 30);

Future<void> _handleUpgrade(HttpRequest req, _Opts opts) async {
  final WebSocket socket;
  try {
    socket = await WebSocketTransformer.upgrade(req);
  } catch (e) {
    stderr.writeln('WebSocket upgrade failed: $e');
    return;
  }
  socket.pingInterval = _kPingInterval;
  try {
    await _Session(socket, opts).run();
  } catch (e) {
    // A session error ends that session only; unawaited, it would
    // otherwise be an uncaught error that kills the whole proxy.
    stderr.writeln('session ended with an error: $e');
  } finally {
    // After the session has closed its DB connection.
    try {
      await socket.close();
    } catch (_) {}
  }
}

class _Session {
  _Session(this.socket, this.opts);
  final WebSocket socket;
  final _Opts opts;
  pg.Connection? _conn;
  PgSession? _pgSession;

  /// Running `execute` messages by id, each with the completer its `cancel`
  /// message fires. They run concurrently (the driver queues them) because
  /// this loop has to stay free to read that `cancel`.
  final Map<Object?, Completer<void>> _running = {};
  final Set<Future<void>> _inFlight = {};

  /// A client on a dropped socket can't be waited for, but one that said
  /// `close` gets its running statements finished first.
  var _closeGracefully = false;

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
        try {
          switch (type) {
            case 'open':
              await _onOpen(msg);
            case 'execute':
              await _startExecute(msg);
            case 'cancel':
              final cancel = _running[msg['id']];
              if (cancel != null && !cancel.isCompleted) cancel.complete();
            case 'close':
              _closeGracefully = true;
              await Future.wait(_inFlight);
              return;
            default:
              await _send({'type': 'error', 'message': 'unknown type "$type"'});
          }
          // The handlers read fields with `as` casts, so a field of the wrong
          // type (`"port": "x"`) from this untrusted peer is a TypeError.
          // Reject that message and keep the session.
          // ignore: avoid_catching_errors
        } on TypeError catch (e) {
          await _send({
            'type': 'error',
            'id': msg['id']?.toString(),
            'message': 'malformed message: $e',
          });
        }
      }
    } finally {
      try {
        await _conn?.close(force: !_closeGracefully);
      } catch (_) {}
    }
  }

  Future<void> _startExecute(Map<String, Object?> msg) async {
    if (_inFlight.length >= _kMaxInFlightStatements) {
      await _send({
        'type': 'error',
        'id': msg['id']?.toString(),
        'message': 'too many statements running on this connection',
      });
      return;
    }
    final done = Completer<void>();
    _inFlight.add(done.future);
    unawaited(
      _executeGuarded(msg).whenComplete(() {
        _inFlight.remove(done.future);
        done.complete();
      }),
    );
  }

  /// [_onExecute] no longer runs under the message loop's handler, so a
  /// malformed field is reported here.
  Future<void> _executeGuarded(Map<String, Object?> msg) async {
    try {
      await _onExecute(msg);
      // The handler reads fields with `as` casts from an untrusted peer.
      // ignore: avoid_catching_errors
    } on TypeError catch (e) {
      await _send({
        'type': 'error',
        'id': msg['id']?.toString(),
        'message': 'malformed message: $e',
      });
    }
  }

  Future<void> _onOpen(Map<String, Object?> msg) async {
    if (opts.sharedSecret != null) {
      final got = msg['secret'];
      if (got is! String || !_constantTimeEquals(got, opts.sharedSecret!)) {
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
    if (!_dbHostAllowed(host, port, opts)) {
      await _send({
        'type': 'error',
        'message': 'this proxy does not open $host:$port (see its --allow-db-host)',
      });
      await socket.close();
      return;
    }
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
          typeRegistry: enumCodecs.isEmpty ? null : pg.TypeRegistry(codecs: enumCodecs),
        ),
      );
      _pgSession = PgSession(_conn!);
      await _send({'type': 'ready'});
    } catch (e) {
      await _send({'type': 'error', 'message': 'open failed: $e'});
      await socket.close();
    }
  }

  Future<void> _onExecute(Map<String, Object?> msg) async {
    final session = _pgSession;
    final id = msg['id'] as String?;
    if (session == null) {
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
    // The proxy's own limit always applies, so a client can't make this
    // process hold a whole table.
    final requested = (msg['maxRows'] as num?)?.toInt() ?? opts.maxRows;
    final rawMode = msg['rowCapMode'] as String?;
    final mode = rawMode == null
        ? RowCapMode.readAndDrop
        : RowCapMode.values.where((value) => value.name == rawMode).firstOrNull;
    if (mode == null) {
      await _send({'type': 'error', 'id': id, 'message': 'unknown rowCapMode "$rawMode"'});
      return;
    }
    final cancel = Completer<void>();
    _running[id] = cancel;
    try {
      final run = await session.run(
        sql,
        positional: named is Map || positional is! List ? null : positional,
        named: named is Map ? named.map((k, v) => MapEntry(k.toString(), v)) : null,
        rowCap: RowCap(requested.clamp(0, opts.maxRows), mode: mode),
        cancelRequested: cancel.future,
      );
      final columns = run.schema?.columns ?? const <pg.ResultSchemaColumn>[];
      final isArray = [
        for (final column in columns) PgValueText.isArrayTypeName(pgTypeNameForOid(column.type.oid)),
      ];
      await _send({
        'type': 'result',
        'id': id,
        'columns': [
          for (final c in columns)
            {
              'name': c.columnName ?? '',
              'typeOid': c.type.oid,
            },
        ],
        'rows': [
          for (final row in run.rows)
            [
              for (var i = 0; i < row.length; i++)
                _serialize(PgValueText.decode(row[i], isArray: isArray[i])),
            ],
        ],
        'affected': run.affectedRows,
        if (run.truncated) 'truncated': true,
        if (run.cancelled) 'cancelled': true,
      });
      // A TypeError is the malformed-message case, reported by the caller.
      // ignore: avoid_catching_errors
    } on TypeError {
      rethrow;
    } catch (e) {
      String? code;
      String? constraint;
      if (e is pg.ServerException) {
        code = e.code;
        constraint = e.constraintName;
      }
      await _send({
        'type': 'error',
        'id': id,
        'code': ?code,
        'constraintName': ?constraint,
        'message': e.toString(),
      });
    } finally {
      _running.remove(id);
    }
  }

  Object? _serialize(Object? v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is List<int>) {
      // Bytes — base64-encode with a discriminator.
      return {'_b64': base64Encode(v)};
    }
    if (v is List) {
      return [for (final e in v) _serialize(e)];
    }
    if (v is Map) {
      return {
        for (final entry in v.entries) entry.key.toString(): _serialize(entry.value),
      };
    }
    return v.toString();
  }

  Future<void> _send(Map<String, Object?> msg) async {
    // A statement can outlive the socket now that they run concurrently.
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(msg));
  }
}

/// Whether a client may open [host]:[port]. With no `--allow-db-host` any
/// database is allowed; with one, only the listed entries are, each either
/// `host` (any port) or `host:port`. Host names compare case-insensitively.
bool _dbHostAllowed(String host, int port, _Opts opts) {
  if (opts.allowDbHosts.isEmpty) return true;
  final h = host.trim().toLowerCase();
  return opts.allowDbHosts.contains(h) || opts.allowDbHosts.contains('$h:$port');
}

/// Compares secrets in time that depends only on their lengths, so a
/// caller can't learn the secret one character at a time by timing replies.
bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

class _Opts {
  _Opts({
    required this.host,
    required this.port,
    required this.sharedSecret,
    required this.allowOrigins,
    required this.allowAnyOrigin,
    required this.allowDbHosts,
    required this.maxRows,
  });
  final String host;
  final int port;
  final String? sharedSecret;
  final Set<String> allowOrigins;
  final bool allowAnyOrigin;
  final Set<String> allowDbHosts;

  /// Most rows one result sends back; the rest are dropped and the reply
  /// carries `"truncated": true`. Bounds the proxy's and the browser's
  /// memory for an unbounded `SELECT *`. dbscope's own grids page far below
  /// it (query tabs stop at 10 000 rows).
  final int maxRows;
}

const _kDefaultMaxRows = 100000;

_Opts _parseArgs(List<String> args) {
  var host = '127.0.0.1';
  var port = 8765;
  String? secret;
  final allow = <String>{};
  var allowAny = false;
  final dbHosts = <String>{};
  var maxRows = _kDefaultMaxRows;
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
        final raw = next();
        final parsed = int.tryParse(raw);
        if (parsed == null || parsed < 0 || parsed > 65535) {
          stderr.writeln('--port needs a number from 0 to 65535, got "$raw"');
          exit(2);
        }
        port = parsed;
      case '--shared-secret':
        secret = next();
      case '--allow-origin':
        allow.add(next());
      case '--allow-any-origin':
        allowAny = true;
      case '--allow-db-host':
        dbHosts.add(next().trim().toLowerCase());
      case '--max-rows':
        final raw = next();
        final parsed = int.tryParse(raw);
        if (parsed == null || parsed < 1) {
          stderr.writeln('--max-rows needs a positive number, got "$raw"');
          exit(2);
        }
        maxRows = parsed;
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
    allowOrigins: allow,
    allowAnyOrigin: allowAny,
    allowDbHosts: dbHosts,
    maxRows: maxRows,
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
 --allow-origin ORIGIN Accept WebSocket upgrades only from this Origin
                       (repeatable). Without it: the hosted web app and
                       localhost pages.
 --allow-any-origin    Accept any Origin. Any web page the user opens
                       can then reach your databases through the proxy.
 --allow-db-host HOST[:PORT]
                       Only open this database (repeatable). Without it,
                       a client may open any host the proxy can reach.
 --max-rows N          Most rows one result returns (default 100000);
                       longer results are cut and flagged "truncated".
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

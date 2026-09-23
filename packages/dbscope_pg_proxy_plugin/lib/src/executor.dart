// DbExecutor backed by dbscope_pg_proxy. Owns one WebSocket
// connection that the proxy maps to one upstream Postgres connection.
//
// The wire protocol is documented in packages/dbscope_pg_proxy/README.md;
// this file is the only place that knows about JSON envelopes — callers
// see the standard DbExecutor surface.
//
// Cancellation: the WebSocket has no per-message cancel, so we honour
// the CancelToken before returning rows (best effort). Closing the
// executor with force: true drops the socket, which causes the proxy
// to close its upstream Postgres connection — same shape as
// PostgresExecutor's close-to-cancel pattern.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'plugin.dart' show kPgProxyKind;

class PgProxyException implements Exception {
  final String? code;
  final String message;
  final String? constraintName;
  PgProxyException(this.message, {this.code, this.constraintName});
  @override
  String toString() => message;
}

class PgProxyExecutor implements DbExecutor {
  final WebSocketChannel _channel;
  final _Uuid _ids = _Uuid();
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;
  bool _readOnly = false;

  PgProxyExecutor._(this._channel) {
    _sub = _channel.stream.listen(_onFrame, onError: _onError, onDone: _onDone);
  }

  static Future<PgProxyExecutor> open(ConnectionProfile profile) async {
    final extra = profile.extra;
    final proxyUrl = (extra['proxyUrl'] as String?) ?? '';
    if (proxyUrl.isEmpty) {
      throw StateError('PgProxy profile has no proxyUrl set.');
    }
    final channel = WebSocketChannel.connect(Uri.parse(proxyUrl));
    await channel.ready;
    final exec = PgProxyExecutor._(channel);
    final openMsg = <String, Object?>{
      'type': 'open',
      'host': profile.host,
      'port': profile.port,
      'database': profile.database,
      'username': profile.username,
      'password': profile.password,
      'sslMode': _sslName(profile.sslMode),
      if ((extra['sharedSecret'] as String?)?.isNotEmpty ?? false)
        'secret': extra['sharedSecret'],
    };
    final ready = Completer<void>();
    exec._readyCompleter = ready;
    exec._channel.sink.add(jsonEncode(openMsg));
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      await exec.close(force: true);
      rethrow;
    }
    return exec;
  }

  Completer<void>? _readyCompleter;

  @override
  String get kind => kPgProxyKind;

  @override
  bool get isOpen => !_closed;

  @override
  DbCapabilities get capabilities => const DbCapabilities(
    sessionReadOnly: false,
    cancelByClose: true,
    dml: true,
    transactions: false,
  );

  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
  }) async {
    if (_closed) {
      throw StateError('PgProxy executor is closed');
    }
    final id = _ids.next();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final msg = <String, Object?>{
      'type': 'execute',
      'id': id,
      'sql': sql,
      if (named != null) 'named': named.map((k, v) => MapEntry(k, _wire(v))),
      if (named == null && positional != null)
        'positional': [for (final v in positional) _wire(v)],
    };
    _channel.sink.add(jsonEncode(msg));
    final reply = await completer.future;
    if (cancelToken?.isCancelled ?? false) {
      return const DbResult(columns: [], rows: []);
    }
    if (reply['type'] == 'error') {
      throw PgProxyException(
        (reply['message'] as String?) ?? 'unknown error',
        code: reply['code'] as String?,
        constraintName: reply['constraintName'] as String?,
      );
    }
    final cols = [
      for (final c in (reply['columns'] as List? ?? const []))
        if (c is Map)
          DbColumn(
            name: (c['name'] as String?) ?? '',
            typeName: c['typeName'] as String?,
          ),
    ];
    final rows = <List<Object?>>[
      for (final row in (reply['rows'] as List? ?? const []))
        if (row is List) [for (final v in row) _decode(v)],
    ];
    final affected = (reply['affected'] as num?)?.toInt() ?? 0;
    return DbResult(columns: cols, rows: rows, affectedRows: affected);
  }

  @override
  Future<void> setReadOnly(bool readOnly) async {
    // Proxy doesn't currently expose a session-toggle. Pretend it
    // worked so the UI can reflect the requested state, but
    // capabilities.sessionReadOnly is false so callers know not to
    // depend on it.
    _readOnly = readOnly;
  }

  bool get readOnly => _readOnly;

  @override
  Future<void> close({bool force = false}) async {
    if (_closed) return;
    _closed = true;
    try {
      if (!force) {
        _channel.sink.add(jsonEncode({'type': 'close'}));
      }
    } catch (_) {}
    try {
      await _channel.sink.close();
    } catch (_) {}
    await _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('connection closed'));
      }
    }
    _pending.clear();
  }

  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    Map<String, Object?> msg;
    try {
      msg = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final type = msg['type'];
    if (type == 'ready') {
      final r = _readyCompleter;
      if (r != null && !r.isCompleted) r.complete();
      return;
    }
    if (type == 'error' && msg['id'] == null) {
      // Pre-ready error: fail the readyCompleter so open() rejects.
      final r = _readyCompleter;
      if (r != null && !r.isCompleted) {
        r.completeError(
          PgProxyException((msg['message'] as String?) ?? 'proxy error'),
        );
      }
      return;
    }
    final id = msg['id'];
    if (id is! String) return;
    final c = _pending.remove(id);
    if (c == null) return;
    c.complete(msg);
  }

  void _onError(Object e, StackTrace st) {
    final r = _readyCompleter;
    if (r != null && !r.isCompleted) r.completeError(e, st);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e, st);
    }
    _pending.clear();
  }

  void _onDone() {
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('proxy WebSocket closed'));
      }
    }
    _pending.clear();
  }
}

Object? _wire(Object? v) {
  if (v == null) return null;
  if (v is String || v is num || v is bool) return v;
  if (v is DateTime) return v.toUtc().toIso8601String();
  if (v is Uint8List) return {'_b64': base64Encode(v)};
  if (v is List<int>) return {'_b64': base64Encode(v)};
  return v.toString();
}

Object? _decode(Object? v) {
  if (v is Map && v['_b64'] is String) {
    return base64Decode(v['_b64'] as String);
  }
  return v;
}

String _sslName(SslMode m) {
  switch (m) {
    case SslMode.disable:
      return 'disable';
    case SslMode.require:
      return 'require';
    case SslMode.verifyFull:
      return 'verify-full';
  }
}

class _Uuid {
  final Uuid _u = const Uuid();
  String next() => _u.v4();
}

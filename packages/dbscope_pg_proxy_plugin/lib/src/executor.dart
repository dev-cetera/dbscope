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

/// How long to wait for the proxy to confirm the upstream database is open
/// before giving up on the connection.
const _kReadyTimeout = Duration(seconds: 15);

class PgProxyException implements Exception {
  PgProxyException(this.message, {this.code, this.constraintName});
  final String? code;
  final String message;
  final String? constraintName;
  @override
  String toString() => message;
}

class PgProxyExecutor implements DbExecutor {
  PgProxyExecutor._(this._channel) {
    _sub = _channel.stream.listen(_onFrame, onError: _onError, onDone: _onDone);
  }
  final WebSocketChannel _channel;
  final _ids = _Uuid();
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  StreamSubscription<dynamic>? _sub;
  var _closed = false;
  var _readOnly = false;

  static Future<PgProxyExecutor> open(ConnectionProfile profile) async {
    final extra = profile.extra;
    final proxyUrl = (extra['proxyUrl'] as String?) ?? '';
    if (proxyUrl.isEmpty) {
      throw StateError('PgProxy profile has no proxyUrl set.');
    }
    final channel = WebSocketChannel.connect(Uri.parse(proxyUrl));
    await channel.ready;
    final executor = PgProxyExecutor._(channel);
    final openMessage = <String, Object?>{
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
    executor._readyCompleter = ready;
    executor._channel.sink.add(jsonEncode(openMessage));
    try {
      await ready.future.timeout(_kReadyTimeout);
    } catch (e) {
      await executor.close(force: true);
      rethrow;
    }
    return executor;
  }

  Completer<void>? _readyCompleter;

  @override
  String get kind => kPgProxyKind;

  @override
  bool get isOpen => !_closed;

  @override
  DbCapabilities get capabilities => const DbCapabilities(
    cancelByClose: true,
    dml: true,
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
    final message = <String, Object?>{
      'type': 'execute',
      'id': id,
      'sql': sql,
      if (named != null)
        'named': named.map((key, value) => MapEntry(key, _wire(value))),
      if (named == null && positional != null)
        'positional': [for (final value in positional) _wire(value)],
    };
    _channel.sink.add(jsonEncode(message));
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
    final columns = [
      for (final columnJson in (reply['columns'] as List? ?? const []))
        if (columnJson is Map)
          DbColumn(
            name: (columnJson['name'] as String?) ?? '',
            typeName: columnJson['typeName'] as String?,
          ),
    ];
    final rows = <List<Object?>>[
      for (final row in (reply['rows'] as List? ?? const []))
        if (row is List) [for (final value in row) _decode(value)],
    ];
    final affected = (reply['affected'] as num?)?.toInt() ?? 0;
    return DbResult(columns: columns, rows: rows, affectedRows: affected);
  }

  @override
  Future<void> setReadOnly({required bool readOnly}) async {
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
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('connection closed'));
      }
    }
    _pending.clear();
  }

  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    Map<String, Object?> message;
    try {
      message = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final type = message['type'];
    if (type == 'ready') {
      final readyCompleter = _readyCompleter;
      if (readyCompleter != null && !readyCompleter.isCompleted) {
        readyCompleter.complete();
      }
      return;
    }
    if (type == 'error' && message['id'] == null) {
      // Pre-ready error: fail the readyCompleter so open() rejects.
      final readyCompleter = _readyCompleter;
      if (readyCompleter != null && !readyCompleter.isCompleted) {
        readyCompleter.completeError(
          PgProxyException((message['message'] as String?) ?? 'proxy error'),
        );
      }
      return;
    }
    final id = message['id'];
    if (id is! String) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.complete(message);
  }

  void _onError(Object e, StackTrace st) {
    final readyCompleter = _readyCompleter;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.completeError(e, st);
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(e, st);
    }
    _pending.clear();
  }

  void _onDone() {
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('proxy WebSocket closed'));
      }
    }
    _pending.clear();
  }
}

Object? _wire(Object? value) {
  if (value == null) return null;
  if (value is String || value is num || value is bool) return value;
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Uint8List) return {'_b64': base64Encode(value)};
  if (value is List<int>) return {'_b64': base64Encode(value)};
  return value.toString();
}

Object? _decode(Object? value) {
  if (value is Map && value['_b64'] is String) {
    return base64Decode(value['_b64'] as String);
  }
  return value;
}

String _sslName(SslMode mode) {
  switch (mode) {
    case SslMode.disable:
      return 'disable';
    case SslMode.require:
      return 'require';
    case SslMode.verifyFull:
      return 'verify-full';
  }
}

class _Uuid {
  final _u = const Uuid();
  String next() => _u.v4();
}

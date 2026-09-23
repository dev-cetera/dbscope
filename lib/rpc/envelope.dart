// JSON envelope shared by every transport. Everything that crosses a
// transport boundary is serialized to one of these so the wire format is
// identical whether the transport is in-process, between Flutter windows,
// or eventually over a network socket.
//
// Wire shape:
// {v, id, kind, method?, params?, result?, error?, topic?}
//
// kind:
// - "req" request-response
// - "res" response to a req with matching id
// - "sub" open a stream (request that yields multiple "evt" frames)
// - "unsub" close a subscription
// - "evt" event in a subscription, id matches the sub
// - "end" subscription closed normally
// - "err" subscription closed with an error
//
// id: opaque string assigned by client; server echoes it on responses and
// events. Caller correlates by id.

import 'dart:convert';

const int kProtocolVersion = 1;

enum EnvelopeKind {
  req('req'),
  res('res'),
  sub('sub'),
  unsub('unsub'),
  evt('evt'),
  end('end'),
  err('err')
  ;

  final String wire;
  const EnvelopeKind(this.wire);

  static EnvelopeKind parse(String s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    throw FormatException('unknown envelope kind: $s');
  }
}

class RpcError implements Exception {
  final String code;
  final String message;
  final Object? data;
  const RpcError(this.code, this.message, {this.data});

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (data != null) 'data': data,
  };

  static RpcError fromJson(Map<String, Object?> json) => RpcError(
    json['code'] as String? ?? 'unknown',
    json['message'] as String? ?? '',
    data: json['data'],
  );

  @override
  String toString() => 'RpcError($code): $message';
}

class Envelope {
  final int v;
  final String id;
  final EnvelopeKind kind;
  final String? method;
  final Object? params;
  final Object? result;
  final RpcError? error;

  const Envelope({
    this.v = kProtocolVersion,
    required this.id,
    required this.kind,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  Envelope.req(this.id, this.method, this.params)
    : v = kProtocolVersion,
      kind = EnvelopeKind.req,
      result = null,
      error = null;

  Envelope.res(this.id, this.result)
    : v = kProtocolVersion,
      kind = EnvelopeKind.res,
      method = null,
      params = null,
      error = null;

  Envelope.resError(this.id, RpcError this.error)
    : v = kProtocolVersion,
      kind = EnvelopeKind.res,
      method = null,
      params = null,
      result = null;

  Envelope.sub(this.id, this.method, this.params)
    : v = kProtocolVersion,
      kind = EnvelopeKind.sub,
      result = null,
      error = null;

  Envelope.unsub(this.id)
    : v = kProtocolVersion,
      kind = EnvelopeKind.unsub,
      method = null,
      params = null,
      result = null,
      error = null;

  Envelope.evt(this.id, this.result)
    : v = kProtocolVersion,
      kind = EnvelopeKind.evt,
      method = null,
      params = null,
      error = null;

  Envelope.end(this.id)
    : v = kProtocolVersion,
      kind = EnvelopeKind.end,
      method = null,
      params = null,
      result = null,
      error = null;

  Envelope.err(this.id, RpcError this.error)
    : v = kProtocolVersion,
      kind = EnvelopeKind.err,
      method = null,
      params = null,
      result = null;

  Map<String, Object?> toJson() => {
    'v': v,
    'id': id,
    'kind': kind.wire,
    if (method != null) 'method': method,
    if (params != null) 'params': params,
    if (result != null) 'result': result,
    if (error != null) 'error': error!.toJson(),
  };

  static Envelope fromJson(Map<String, Object?> json) => Envelope(
    v: (json['v'] as num?)?.toInt() ?? kProtocolVersion,
    id: json['id'] as String,
    kind: EnvelopeKind.parse(json['kind'] as String),
    method: json['method'] as String?,
    params: json['params'],
    result: json['result'],
    error: json['error'] is Map<String, Object?>
        ? RpcError.fromJson(json['error'] as Map<String, Object?>)
        : null,
  );

  String encode() => jsonEncode(toJson());
  static Envelope decode(String wire) =>
      Envelope.fromJson(jsonDecode(wire) as Map<String, Object?>);
}

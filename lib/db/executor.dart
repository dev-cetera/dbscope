// DbExecutor — backend-agnostic SQL execution surface.
//
// Design notes (locked in before migrating the call sites; see plugin
// architecture in lib/db/plugin.dart):
//
// 1. The interface is positional+named parameter aware. Postgres-backed
// implementations forward to pg.Sql / pg.Sql.named; non-Postgres plugins
// (e.g. an HTTP `dbexecute` API) translate to whatever wire format their
// backend wants.
//
// 2. Columns expose `name` and `typeName` only. Backends that return
// untyped rows (string-only payloads, etc.) report `null` typeName and
// callers must degrade gracefully — PgType.unknown for colouring,
// untyped grid cells, etc.
//
// 3. Capability flags let call sites disable features cleanly instead of
// throwing UnsupportedError from a degraded path. Add a flag when a
// real feature can't be supported by some backend, then guard the
// feature with the flag at the UI level.
//
// 4. Cancellation goes through `CancelToken`. Backends that can't actually
// abort an in-flight request still honour the token by checking it
// before returning rows (best effort). Postgres cancels by closing the
// socket; HTTP backends pass the token to their request.

import '../query/cancel_token.dart';

/// Backend-agnostic result of executing one statement.
class DbResult {
  final List<DbColumn> columns;
  final List<List<Object?>> rows;
  final int affectedRows;

  const DbResult({
    required this.columns,
    required this.rows,
    this.affectedRows = 0,
  });

  bool get isEmpty => rows.isEmpty;
  List<Object?> get first => rows.first;
}

/// Column metadata from a result set.
class DbColumn {
  final String name;

  /// Postgres-style type name (e.g. 'int4', 'text'). Null if the backend
  /// doesn't expose types — callers map null to PgType.unknown.
  final String? typeName;
  const DbColumn({required this.name, this.typeName});
}

/// Capability flags. Default to false for safety; backends override
/// `capabilities` to advertise what they support.
class DbCapabilities {
  /// Whether `setReadOnly` is real (SET default_transaction_read_only).
  /// HTTP-mediated backends can't toggle session state.
  final bool sessionReadOnly;

  /// Whether cancelling a query by closing the underlying socket works.
  final bool cancelByClose;

  /// Whether the backend supports DML at all (INSERT/UPDATE/DELETE).
  final bool dml;

  /// Whether multi-statement transactions are supported.
  final bool transactions;

  const DbCapabilities({
    this.sessionReadOnly = false,
    this.cancelByClose = false,
    this.dml = false,
    this.transactions = false,
  });

  static const postgres = DbCapabilities(
    sessionReadOnly: true,
    cancelByClose: true,
    dml: true,
    transactions: true,
  );
}

/// Abstract execution surface. Implementations are owned by a
/// ConnectionRegistry entry (per window) and/or a ConnectionService entry
/// (server-side) and are created by the kind plugin that owns the profile.
abstract class DbExecutor {
  /// The plugin kind that produced this executor (e.g. 'postgres',
  /// 'sqlite'). Used by call sites that need to branch by backend or
  /// gate features.
  String get kind;

  bool get isOpen;

  DbCapabilities get capabilities;

  /// Execute one statement. Pass exactly one of [positional] / [named].
  /// When neither is supplied the SQL is sent raw (no parameters).
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
  });

  /// Toggle session read-only behaviour. Real Postgres backends issue
  /// `SET default_transaction_read_only = {ON,OFF}`. Backends without
  /// session state should make this a no-op (and report
  /// `capabilities.sessionReadOnly == false`).
  Future<void> setReadOnly(bool readOnly);

  /// Close the executor. `force = true` is the "abort whatever is in
  /// flight" path used by the user-facing Stop button — Postgres-backed
  /// executors close the socket to cancel a long-running query.
  Future<void> close({bool force = false});
}

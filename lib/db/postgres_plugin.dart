import 'package:flutter/material.dart';
import 'package:postgres/postgres.dart' as pg;

import '../connection/connection_dialog.dart';
import '../connection/profile.dart';
import '../plugins/dbscope_plugin.dart';
import 'plugin.dart';
import 'postgres_executor.dart';

/// Universal-plugin wrapper for the built-in Postgres kind. The host
/// registers this alongside external plugins so the registration shape
/// is identical for built-ins and third-party plugins.
class PostgresPlugin extends DbscopePlugin {
  @override
  String get id => kPostgresKind;
  @override
  String get label => 'PostgreSQL';

  @override
  void register(DbscopeHost host) {
    host.connections.register(const PostgresKindPlugin());
  }
}

/// Built-in postgres kind. Owns the legacy TCP-based connection path —
/// reads host/port/database/username/password/sslMode straight off the
/// profile and opens a pg.Connection.
class PostgresKindPlugin implements ConnectionKindPlugin {
  const PostgresKindPlugin();

  @override
  String get id => kPostgresKind;

  @override
  String get label => 'PostgreSQL';

  @override
  Future<OpenResult> open(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    final conn = await openConnection(
      host: profile.host,
      port: profile.port,
      database: profile.database,
      username: profile.username,
      password: profile.password,
      sslMode: profile.sslMode,
    );
    return OpenResult(executor: PostgresExecutor(conn));
  }

  /// Open a ready-to-use `pg.Connection`, including the two-step enum-codec
  /// discovery. Shared with other kinds that ultimately speak Postgres
  /// (e.g. the Cloud SQL kind, which tunnels through a local proxy).
  ///
  /// package:postgres only accepts a TypeRegistry at construction time, but
  /// the OIDs of user-defined enum types aren't known until we query
  /// pg_catalog. So: open a short-lived discovery connection, learn the enum
  /// OIDs, close it, then open the real connection with a TypeRegistry that
  /// decodes those OIDs as their text label (otherwise enum values come back
  /// as UndecodedBytes and render as bytea hex like \x50415353574f5244).
  static Future<pg.Connection> openConnection({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
    SslMode sslMode = SslMode.disable,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final endpoint = pg.Endpoint(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
    );
    final mode = _sslMap(sslMode);

    final discovery = await pg.Connection.open(
      endpoint,
      settings: pg.ConnectionSettings(sslMode: mode, connectTimeout: timeout),
    );
    final Map<int, pg.Codec> enumCodecs;
    try {
      enumCodecs = await PostgresExecutor.loadEnumCodecs(discovery);
    } finally {
      try {
        await discovery.close();
      } catch (_) {}
    }

    return pg.Connection.open(
      endpoint,
      settings: pg.ConnectionSettings(
        sslMode: mode,
        connectTimeout: timeout,
        typeRegistry: enumCodecs.isEmpty
            ? null
            : pg.TypeRegistry(codecs: enumCodecs),
      ),
    );
  }

  @override
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  }) {
    return showDialog<ConnectionProfile>(
      context: context,
      builder: (_) => ConnectionDialog(initial: initial),
    );
  }

  static pg.SslMode _sslMap(SslMode m) {
    switch (m) {
      case SslMode.disable:
        return pg.SslMode.disable;
      case SslMode.require:
        return pg.SslMode.require;
      case SslMode.verifyFull:
        return pg.SslMode.verifyFull;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:postgres/postgres.dart' as pg;

import '../../connection/profile.dart';
import '../../plugins/dbscope_plugin.dart';
import '../plugin.dart';
import '../postgres_plugin.dart';
import 'cloudsql_config.dart';
import 'cloudsql_dialog.dart';
import 'cloudsql_executor.dart';
import 'cloudsql_proxy_manager.dart';

/// How long to keep retrying while a freshly-assigned public IP warms up.
const _kOpenRetryWindow = Duration(seconds: 75);

/// Pause between open attempts while retrying.
const _kOpenRetryDelay = Duration(seconds: 2);

/// Universal-plugin wrapper for the Cloud SQL kind. Registered on IO
/// platforms only (it shells out to `cloud-sql-proxy` / `gcloud`).
class CloudSqlPlugin extends DbscopePlugin {
  @override
  String get id => kCloudSqlKind;
  @override
  String get label => 'Cloud SQL (Postgres)';

  @override
  void register(DbscopeHost host) {
    host.connections.register(const CloudSqlKindPlugin());
  }
}

/// Connection kind that reaches a Cloud SQL Postgres instance through a
/// locally-launched Cloud SQL Auth Proxy. `open` ensures the tunnel is up
/// (assigning a public IP first if configured), then opens Postgres against
/// `127.0.0.1:<localPort>` exactly like the built-in Postgres kind.
class CloudSqlKindPlugin implements ConnectionKindPlugin {
  const CloudSqlKindPlugin();

  @override
  String get id => kCloudSqlKind;

  @override
  String get label => 'Cloud SQL (Postgres)';

  @override
  Future<OpenResult> open(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    final config = CloudSqlConfig.fromProfile(profile);
    if (config.instanceConnectionName.isEmpty) {
      throw const CloudSqlProxyException(
        'This Cloud SQL connection has no instance connection name '
        '(project:region:instance).',
      );
    }

    await CloudSqlProxyManager.instance.acquire(
      config,
      onStatus: (status) => debugPrint('[cloudsql] $status'),
    );

    try {
      final connection = await _openWithRetry(config, profile);
      return OpenResult(executor: CloudSqlExecutor(connection, config));
    } catch (_) {
      // Opening the DB failed — hand the tunnel back so it's torn down if we
      // were the only user.
      await CloudSqlProxyManager.instance.release(config);
      rethrow;
    }
  }

  /// A freshly-assigned public IP can take tens of seconds to actually
  /// accept connections; during that window the proxy accepts locally but
  /// the dial fails ("server closed the connection unexpectedly"). Retry
  /// transient failures until the deadline, but fail fast on auth errors so
  /// a wrong password doesn't hang for a minute.
  Future<pg.Connection> _openWithRetry(
    CloudSqlConfig config,
    ConnectionProfile profile,
  ) async {
    final deadline = DateTime.now().add(_kOpenRetryWindow);
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await PostgresKindPlugin.openConnection(
          host: '127.0.0.1',
          port: config.localPort,
          database: profile.database,
          username: profile.username,
          password: profile.password,
        );
      } catch (e) {
        if (!_isTransient(e) || DateTime.now().isAfter(deadline)) {
          rethrow;
        }
        debugPrint('[cloudsql] open attempt $attempt failed, retrying: $e');
        await Future<void>.delayed(_kOpenRetryDelay);
      }
    }
  }

  bool _isTransient(Object e) {
    final message = e.toString().toLowerCase();
    // Auth / config problems won't fix themselves — don't retry them.
    const fatal = [
      'password authentication',
      'authentication failed',
      'does not exist', // missing role/database
      'no pg_hba',
    ];
    return !fatal.any(message.contains);
  }

  @override
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  }) {
    return showDialog<ConnectionProfile>(
      context: context,
      builder: (_) => CloudSqlDialog(initial: initial),
    );
  }
}

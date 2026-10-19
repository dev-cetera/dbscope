import 'dart:io';

import 'package:uuid/uuid.dart';

import '../db/cloudsql/cloudsql_config.dart';
import 'profile.dart';

/// Builds the profile to auto-connect to on startup, from `DBSCOPE_AUTO_*`
/// environment variables — the command-line alternative to picking a
/// connection by hand or importing a `.dbscopeconn` link.
///
/// `backend/scripts/dbscope/start_dbscope.sh` (in the compledo repo) sets these
/// and launches `flutter run -d macos`, so `start_dbscope.sh local` / `dev` /
/// `prod` opens dbscope already pointed at the right database. A plain
/// desktop launch (double-clicking the app, or `flutter run` with no env)
/// sets none of these, so [autoConnectProfileFromEnv] returns null and
/// `main.dart` falls back to restoring the last-used connection as usual.
///
/// Required: `DBSCOPE_AUTO_HOST`, `DBSCOPE_AUTO_DATABASE`,
/// `DBSCOPE_AUTO_USERNAME`. Optional: `DBSCOPE_AUTO_PORT` (default 5432),
/// `DBSCOPE_AUTO_PASSWORD`, `DBSCOPE_AUTO_NAME` (the connection's label),
/// `DBSCOPE_AUTO_READ_ONLY` (`true`/`false`). Set
/// `DBSCOPE_AUTO_CLOUDSQL_INSTANCE` (`project:region:instance`) to open a
/// Cloud SQL profile instead of a plain Postgres one — dbscope then
/// launches its own Cloud SQL Auth Proxy (see
/// `lib/db/cloudsql/cloudsql_plugin.dart`) rather than connecting directly,
/// and `DBSCOPE_AUTO_HOST`/`DBSCOPE_AUTO_PORT` describe the proxy's local
/// address (always `127.0.0.1`); `DBSCOPE_AUTO_GCP_PROJECT` and
/// `DBSCOPE_AUTO_ASSIGN_IP` (default `true`) tune the proxy.
///
/// The returned profile has a **stable id** derived from the connection's
/// own identity (host/port/database/username), so re-running `start_dbscope.sh`
/// updates the same saved profile instead of piling up a fresh one in the
/// picker every launch.
ConnectionProfile? autoConnectProfileFromEnv() {
  final env = Platform.environment;
  final host = env['DBSCOPE_AUTO_HOST'];
  if (host == null || host.isEmpty) return null;
  final database = env['DBSCOPE_AUTO_DATABASE'] ?? 'postgres';
  final username = env['DBSCOPE_AUTO_USERNAME'] ?? 'postgres';
  final port = int.tryParse(env['DBSCOPE_AUTO_PORT'] ?? '') ?? 5432;
  final password = env['DBSCOPE_AUTO_PASSWORD'] ?? '';
  final name = env['DBSCOPE_AUTO_NAME'] ?? '$username@$host/$database';
  final readOnlyRaw = env['DBSCOPE_AUTO_READ_ONLY'];
  final readOnly = readOnlyRaw == null ? null : readOnlyRaw == 'true';
  final id = const Uuid().v5(
    Namespace.url.value,
    'dbscope-cli:$host:$port:$database:$username',
  );

  final instance = env['DBSCOPE_AUTO_CLOUDSQL_INSTANCE'];
  if (instance == null || instance.isEmpty) {
    return ConnectionProfile(
      id: id,
      name: name,
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      readOnly: readOnly,
    );
  }

  final segments = instance.split(':');
  final cloudSql = CloudSqlConfig(
    instanceConnectionName: instance,
    gcpProject: env['DBSCOPE_AUTO_GCP_PROJECT'] ?? segments.first,
    instanceName: segments.last,
    localPort: port,
    assignPublicIp: (env['DBSCOPE_AUTO_ASSIGN_IP'] ?? 'true') != 'false',
  );
  return ConnectionProfile(
    id: id,
    kind: kCloudSqlKind,
    name: name,
    host: host,
    port: port,
    database: database,
    username: username,
    password: password,
    readOnly: readOnly,
    extra: cloudSql.toExtra(),
  );
}

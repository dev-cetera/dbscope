import 'package:uuid/uuid.dart';

import '../db/cloudsql/cloudsql_config.dart';
import '../util/portable_io.dart';
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
/// `DBSCOPE_AUTO_READ_ONLY` (`true`/`false`, also `1`/`0`, `yes`/`no`). Set
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
///
/// [environment] defaults to the process environment (tests pass their own).
ConnectionProfile? autoConnectProfileFromEnv([Map<String, String>? environment]) {
  final env = environment ?? processEnvironment();
  final host = env['DBSCOPE_AUTO_HOST'];
  if (host == null || host.isEmpty) return null;
  final database = env['DBSCOPE_AUTO_DATABASE'] ?? 'postgres';
  final username = env['DBSCOPE_AUTO_USERNAME'] ?? 'postgres';
  final port = int.tryParse(env['DBSCOPE_AUTO_PORT'] ?? '') ?? 5432;
  final password = env['DBSCOPE_AUTO_PASSWORD'] ?? '';
  final name = env['DBSCOPE_AUTO_NAME'] ?? '$username@$host/$database';
  final readOnly = parseEnvBool(env['DBSCOPE_AUTO_READ_ONLY']);
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
    assignPublicIp: parseEnvBool(env['DBSCOPE_AUTO_ASSIGN_IP']) ?? true,
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

/// `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off`, in any case; null for
/// anything else (unset, empty, a typo), so the profile's read-only
/// heuristic decides. A strict `== 'true'` read `DBSCOPE_AUTO_READ_ONLY=1`
/// or `=TRUE` as read-write, on the variable people set for production.
bool? parseEnvBool(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'true' || '1' || 'yes' || 'on':
      return true;
    case 'false' || '0' || 'no' || 'off':
      return false;
    default:
      return null;
  }
}

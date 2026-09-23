import '../../connection/profile.dart';

/// Kind id serialised in [ConnectionProfile.kind] for Cloud SQL profiles.
const String kCloudSqlKind = 'cloudsql';

/// Cloud SQL-specific settings, persisted opaquely in
/// [ConnectionProfile.extra]. The core never reads these — only the Cloud
/// SQL plugin does.
///
/// A Cloud SQL profile is "a Postgres profile that reaches its instance
/// through the Cloud SQL Auth Proxy". The regular profile fields carry the
/// Postgres side (database, username, password, and the *local* proxy
/// host/port — always 127.0.0.1:[localPort]); [extra] carries what the
/// proxy needs.
class CloudSqlConfig {
  /// Full instance connection name: `project:region:instance`.
  final String instanceConnectionName;

  /// GCP project used for `gcloud sql instances patch` (public-IP toggle).
  /// Defaults to the project segment of [instanceConnectionName].
  final String gcpProject;

  /// Instance short name (the last segment of [instanceConnectionName]),
  /// used by the public-IP patch call.
  final String instanceName;

  /// Local port the proxy listens on (127.0.0.1:[localPort]).
  final int localPort;

  /// Whether dbscope should assign a public IP to the instance before
  /// starting the proxy (and remove it on disconnect). Private-only
  /// instances need this to be reachable from a laptop; on the VPC it's
  /// unnecessary.
  final bool assignPublicIp;

  /// Optional explicit path to the `cloud-sql-proxy` binary. When empty the
  /// plugin resolves it from PATH + common install locations.
  final String cloudSqlProxyPath;

  /// Optional explicit path to the `gcloud` binary. Only used when
  /// [assignPublicIp] is true.
  final String gcloudPath;

  const CloudSqlConfig({
    required this.instanceConnectionName,
    required this.gcpProject,
    required this.instanceName,
    this.localPort = 9480,
    this.assignPublicIp = true,
    this.cloudSqlProxyPath = '',
    this.gcloudPath = '',
  });

  /// A stable key identifying one running proxy (instance + local port).
  String get proxyKey => '$instanceConnectionName@$localPort';

  static const String _kInstance = 'instanceConnectionName';
  static const String _kProject = 'gcpProject';
  static const String _kInstanceName = 'instanceName';
  static const String _kLocalPort = 'localPort';
  static const String _kAssignIp = 'assignPublicIp';
  static const String _kProxyPath = 'cloudSqlProxyPath';
  static const String _kGcloudPath = 'gcloudPath';

  factory CloudSqlConfig.fromProfile(ConnectionProfile profile) {
    final e = profile.extra;
    final icn = (e[_kInstance] as String?)?.trim() ?? '';
    final segments = icn.split(':');
    final derivedProject = segments.isNotEmpty ? segments.first : '';
    final derivedInstance = segments.isNotEmpty ? segments.last : '';
    return CloudSqlConfig(
      instanceConnectionName: icn,
      gcpProject: (e[_kProject] as String?)?.trim().isNotEmpty == true
          ? (e[_kProject] as String).trim()
          : derivedProject,
      instanceName: (e[_kInstanceName] as String?)?.trim().isNotEmpty == true
          ? (e[_kInstanceName] as String).trim()
          : derivedInstance,
      localPort: (e[_kLocalPort] as num?)?.toInt() ?? profile.port,
      assignPublicIp: e[_kAssignIp] as bool? ?? true,
      cloudSqlProxyPath: (e[_kProxyPath] as String?)?.trim() ?? '',
      gcloudPath: (e[_kGcloudPath] as String?)?.trim() ?? '',
    );
  }

  /// Serialise back into the [ConnectionProfile.extra] shape. Empty
  /// optional fields are omitted to keep the JSON tight.
  Map<String, Object?> toExtra() => {
    _kInstance: instanceConnectionName,
    _kProject: gcpProject,
    _kInstanceName: instanceName,
    _kLocalPort: localPort,
    _kAssignIp: assignPublicIp,
    if (cloudSqlProxyPath.isNotEmpty) _kProxyPath: cloudSqlProxyPath,
    if (gcloudPath.isNotEmpty) _kGcloudPath: gcloudPath,
  };
}

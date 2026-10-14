import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../util/shell_env_io.dart';
import 'cloudsql_config.dart';

/// Raised when the Cloud SQL Auth Proxy can't be started (missing binary,
/// gcloud failure, proxy never bound its port, …). Carries a message that's
/// safe to show in a connection-error toast.
class CloudSqlProxyException implements Exception {
  const CloudSqlProxyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Longest we wait for a `gcloud sql instances patch` (assigning or removing
/// a public IP is a slow Cloud SQL operation).
const _kGcloudPatchTimeout = Duration(seconds: 180);

/// Longest we wait for the quick `gcloud sql instances describe` check.
const _kGcloudDescribeTimeout = Duration(seconds: 30);

/// How long a killed proxy process gets to exit before we move on.
const _kProxyExitTimeout = Duration(seconds: 5);

/// How long we wait for a new proxy to start listening on its local port.
const _kProxyBindTimeout = Duration(seconds: 20);

/// How often we re-check whether the proxy has bound its port.
const _kProxyBindPollInterval = Duration(milliseconds: 300);

/// Longest a single "is anything listening on this port?" probe may take.
const _kPortProbeTimeout = Duration(milliseconds: 600);

class _ProxyEntry {
  Process? process;
  var refCount = 0;

  /// True when dbscope started this proxy (so it owns tearing it down).
  /// False when we found one already listening (an external
  /// `db_proxy.sh` / cloud-sql-proxy) and are only borrowing it.
  var owned = false;

  /// True when dbscope assigned the instance a public IP (so it must remove
  /// it on teardown).
  var assignedIp = false;

  /// Completes when the proxy is usable (or with an error if startup failed).
  /// Concurrent acquirers await this instead of racing a second launch.
  Future<void>? ready;

  final log = StringBuffer();
}

/// Per-isolate, reference-counted manager for Cloud SQL Auth Proxy tunnels.
///
/// The proxy is a shared local resource: the host isolate can open a Cloud
/// SQL connection from both the server (jobs) and the host window, and each
/// wants the same 127.0.0.1:port tunnel. This manager launches at most one
/// proxy per (instance, port), ref-counts callers, and tears the tunnel down
/// — killing the process and removing the public IP it assigned — only when
/// the last caller releases it.
///
/// If something is already listening on the local port (e.g. the user ran
/// `backend/scripts/remote/db_proxy.sh prod`), the manager reuses it and
/// never kills it.
class CloudSqlProxyManager {
  CloudSqlProxyManager._();
  static final instance = CloudSqlProxyManager._();

  final Map<String, _ProxyEntry> _entries = {};

  /// Ensure a tunnel is up for [config]. Increments the ref count. Throws
  /// [CloudSqlProxyException] if the tunnel can't be established.
  Future<void> acquire(
    CloudSqlConfig config, {
    void Function(String status)? onStatus,
  }) {
    final key = config.proxyKey;
    final existing = _entries[key];
    if (existing != null) {
      existing.refCount++;
      // Await the same startup the first caller kicked off. If it failed,
      // give this caller the error and undo the ref bump.
      return existing.ready!.catchError((Object e, StackTrace st) {
        existing.refCount--;
        Error.throwWithStackTrace(e, st);
      });
    }
    final entry = _ProxyEntry()..refCount = 1;
    _entries[key] = entry;
    final startup = _startProxy(entry, config, onStatus);
    entry.ready = startup;
    return startup;
  }

  /// Decrement the ref count for [config]'s tunnel. When it reaches zero and
  /// dbscope owns the tunnel, kill the proxy and remove any public IP it
  /// assigned.
  Future<void> release(CloudSqlConfig config) async {
    final entry = _entries[config.proxyKey];
    if (entry == null) return;
    entry.refCount--;
    if (entry.refCount > 0) return;
    _entries.remove(config.proxyKey);
    if (entry.owned) {
      await _teardown(entry, config);
    }
  }

  Future<void> _startProxy(
    _ProxyEntry entry,
    CloudSqlConfig config,
    void Function(String status)? onStatus,
  ) async {
    try {
      if (await _portOpen(config.localPort)) {
        onStatus?.call(
          'Reusing existing tunnel on 127.0.0.1:${config.localPort}.',
        );
        entry.owned = false;
        return;
      }

      final proxyBin = await _resolveBinary(
        'cloud-sql-proxy',
        config.cloudSqlProxyPath,
      );
      if (proxyBin == null) {
        throw const CloudSqlProxyException(
          'cloud-sql-proxy was not found. Install the Cloud SQL Auth Proxy '
          '(https://cloud.google.com/sql/docs/postgres/sql-proxy) or set an '
          'explicit path on the connection.',
        );
      }

      if (config.assignPublicIp) {
        final gcloudBin = await _resolveBinary('gcloud', config.gcloudPath);
        if (gcloudBin == null) {
          throw const CloudSqlProxyException(
            'gcloud was not found — it is needed to assign the instance a '
            'public IP. Install the Google Cloud SDK, disable "assign public '
            'IP" on the connection, or set an explicit gcloud path.',
          );
        }
        // Assigning a public IP is a slow Cloud SQL operation (tens of
        // seconds — even re-assigning an already-public instance blocks on an
        // operation). Skip it when the instance already has one; that's what
        // makes reconnects fast. We only strip the IP on teardown when *we*
        // assigned it (`assignedIp`), so a pre-existing IP is left untouched.
        if (await _hasPublicIp(gcloudBin, config)) {
          onStatus?.call('${config.instanceName} already has a public IP.');
        } else {
          onStatus?.call('Assigning public IP to ${config.instanceName}…');
          final processResult = await Process.run(gcloudBin, [
            'sql',
            'instances',
            'patch',
            config.instanceName,
            '--assign-ip',
            '--project',
            config.gcpProject,
            '--quiet',
          ]).timeout(_kGcloudPatchTimeout);
          if (processResult.exitCode != 0) {
            throw CloudSqlProxyException(
              'Assigning a public IP failed. Check `gcloud auth login` and '
              'that you can reach project ${config.gcpProject}.\n'
              '${_tail(processResult.stderr.toString())}',
            );
          }
          entry.assignedIp = true;
        }
      }

      onStatus?.call(
        'Starting cloud-sql-proxy on 127.0.0.1:${config.localPort}…',
      );
      final proc = await Process.start(proxyBin, [
        config.instanceConnectionName,
        '--port',
        '${config.localPort}',
      ]);
      entry.process = proc;
      entry.owned = true;
      proc.stdout.transform(utf8.decoder).listen(entry.log.write);
      proc.stderr.transform(utf8.decoder).listen(entry.log.write);

      final bound = await _waitBound(config.localPort, proc);
      if (!bound) {
        throw CloudSqlProxyException(
          'cloud-sql-proxy failed to start.\n${_tail(entry.log.toString())}',
        );
      }
      onStatus?.call('Tunnel ready on 127.0.0.1:${config.localPort}.');
    } catch (e) {
      await _teardown(entry, config);
      _entries.remove(config.proxyKey);
      rethrow;
    }
  }

  /// Fast check (~a few seconds) of whether the instance already exposes a
  /// public IP, so we can skip the slow `--assign-ip` patch. Returns false on
  /// any error — the caller then falls back to attempting the assignment.
  Future<bool> _hasPublicIp(String gcloudBin, CloudSqlConfig config) async {
    try {
      final processResult = await Process.run(gcloudBin, [
        'sql',
        'instances',
        'describe',
        config.instanceName,
        '--project',
        config.gcpProject,
        '--format=value(settings.ipConfiguration.ipv4Enabled)',
      ]).timeout(_kGcloudDescribeTimeout);
      if (processResult.exitCode != 0) return false;
      return processResult.stdout.toString().trim().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _teardown(_ProxyEntry entry, CloudSqlConfig config) async {
    final proc = entry.process;
    entry.process = null;
    if (proc != null) {
      proc.kill();
      try {
        await proc.exitCode.timeout(_kProxyExitTimeout);
      } catch (_) {}
    }
    if (entry.assignedIp) {
      entry.assignedIp = false;
      final gcloudBin = await _resolveBinary('gcloud', config.gcloudPath);
      if (gcloudBin != null) {
        try {
          await Process.run(gcloudBin, [
            'sql',
            'instances',
            'patch',
            config.instanceName,
            '--no-assign-ip',
            '--project',
            config.gcpProject,
            '--quiet',
          ]).timeout(_kGcloudPatchTimeout);
        } catch (_) {
          // Best effort — the user can remove the IP manually if this fails.
        }
      }
    }
  }

  /// True as soon as the proxy binds its local port (it does so before the
  /// instance is actually reachable). Instance reachability — e.g. a
  /// freshly-assigned public IP still warming up — is validated by the
  /// Postgres open that follows, which retries during the warmup window.
  Future<bool> _waitBound(int port, Process proc) async {
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(_kProxyBindTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited) return false;
      if (await _portOpen(port)) return true;
      await Future<void>.delayed(_kProxyBindPollInterval);
    }
    return false;
  }

  static Future<bool> _portOpen(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: _kPortProbeTimeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolve [name] to a full path. Honours [explicit] first, then searches
  /// PATH plus common install locations (GUI-launched apps get a minimal
  /// PATH that omits Homebrew / the gcloud SDK).
  static Future<String?> _resolveBinary(String name, String explicit) async {
    if (explicit.isNotEmpty) {
      return File(explicit).existsSync() ? explicit : null;
    }
    final sep = Platform.isWindows ? ';' : ':';
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final dirs = <String>[
      ...(Platform.environment['PATH'] ?? '').split(sep),
      // PATH is the one variable where the shell file supplements the
      // process rather than losing to it: the launchd PATH is real, it
      // just lacks whatever the user's profile prepends.
      ...(ShellEnv.instance.fileValue('PATH') ?? '').split(sep),
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
      if (home.isNotEmpty) ...[
        '$home/google-cloud-sdk/bin',
        '$home/.local/bin',
      ],
      // Deduped: the shell profile's PATH almost always RESTATES most of the
      // process PATH, and the four fallbacks below are usually in both. Every
      // repeat is another File.exists() stat on the connect path.
    ].where((directory) => directory.isNotEmpty).toSet();

    final names = Platform.isWindows
        ? ['$name.exe', '$name.cmd', name]
        : [name];
    for (final directory in dirs) {
      for (final candidateName in names) {
        final candidate = '$directory${Platform.pathSeparator}$candidateName';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  static String _tail(String text, [int max = 1500]) =>
      text.length <= max ? text : text.substring(text.length - max);
}

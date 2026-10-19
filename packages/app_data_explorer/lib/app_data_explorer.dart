// Library API for connecting to Flutter app data on a plugged-in device.
//
// This file contains the reusable logic - device discovery, app listings,
// file operations - with NO stdin/stdout coupling, so it can be imported by:
// - The CLI (`bin/app_data_explorer.dart`)
// - A future Flutter UI (e.g. a local session viewer)
// - Any other Dart entry point (tests, scripts)
//
// Android ops are built on top of `adb` (+ `run-as` on debuggable builds).
// iOS ops are built on top of `xcrun devicectl`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A device or tool failure; [message] is what the caller shows the user.
final class AppDataExplorerException implements Exception {
  const AppDataExplorerException(this.message);
  final String message;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// adb discovery
// ---------------------------------------------------------------------------

String? _adbPath;

/// Resolves `adb` from `$PATH`, then from common Android SDK locations.
/// Returns null if not found anywhere.
String? resolveAdbPath() {
  if (_adbPath != null) return _adbPath;
  try {
    final result = Process.runSync('command', ['-v', 'adb'], runInShell: true);
    if (result.exitCode == 0) {
      final foundPath = (result.stdout as String).trim();
      if (foundPath.isNotEmpty && File(foundPath).existsSync()) {
        return _adbPath = foundPath;
      }
    }
  } catch (_) {}
  final env = Platform.environment;
  final candidates = <String>[
    if (env['ANDROID_HOME'] != null) '${env['ANDROID_HOME']}/platform-tools/adb',
    if (env['ANDROID_SDK_ROOT'] != null) '${env['ANDROID_SDK_ROOT']}/platform-tools/adb',
    '${env['HOME']}/Library/Android/sdk/platform-tools/adb',
    '${env['HOME']}/Android/Sdk/platform-tools/adb',
    '/usr/local/bin/adb',
    '/opt/homebrew/bin/adb',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return _adbPath = candidate;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Backend abstraction
// ---------------------------------------------------------------------------

class Entry {
  Entry(this.name, {required this.isDir, this.sizeBytes});
  final String name;
  final bool isDir;
  final int? sizeBytes;
}

abstract class Backend {
  String get deviceLabel;
  String get appLabel;

  /// Lists immediate children at a path relative to the app data container
  /// root. Each [Entry.name] is the basename, no `/`.
  Future<List<Entry>> ls(String relPath);

  /// Lists every descendant of [relPath] recursively. Each [Entry.name] is
  /// the path RELATIVE to [relPath] (e.g. `Library/Caches/log.txt`). Used by
  /// UIs that want a single round-trip to build a full tree.
  Future<List<Entry>> lsRecursive(String relPath);

  /// Deletes a single file relative to the app data container root.
  Future<void> rm(String relPath);

  /// Wipes the contents of a directory (the dir itself is preserved).
  Future<void> clearDir(String relDir);

  /// Downloads a file to the host filesystem.
  Future<void> pull(String remoteRelPath, String localPath);

  /// Uploads a file from the host filesystem to a path relative to the
  /// app data container root, overwriting if it already exists.
  Future<void> push(String localPath, String remoteRelPath);
}

// ---------------------------------------------------------------------------
// Android backend
// ---------------------------------------------------------------------------

class AndroidBackend extends Backend {
  AndroidBackend({required this.serial, required this.pkg, this.model});

  final String serial;
  final String pkg;
  final String? model;

  @override
  String get deviceLabel => 'android $serial${model == null ? '' : ' ($model)'}';

  @override
  String get appLabel => pkg;

  Future<ProcessResult> _adbShell(String cmd) {
    final adb = resolveAdbPath() ?? 'adb';
    return Process.run(adb, ['-s', serial, 'shell', cmd]);
  }

  String _runAs(String inner) => 'run-as $pkg $inner';

  @override
  Future<List<Entry>> ls(String relPath) async {
    final target = relPath.isEmpty ? '.' : relPath;
    final result = await _adbShell(_runAs('ls -lAp ${_q(target)}'));
    if (result.exitCode != 0) {
      throw AppDataExplorerException(_adbError('ls', result));
    }
    return _parseLsLap(result.stdout as String);
  }

  @override
  Future<List<Entry>> lsRecursive(String relPath) async {
    final base = relPath.isEmpty ? '.' : relPath;
    // Some Android toybox builds reject `find -printf`, so use the more
    // portable `find ... -exec stat ... {} +`. %F is the human-readable file
    // type ("regular file", "directory", "symbolic link"), %s is size, %n is
    // the full path the matcher saw. We use '|' as the separator since %F
    // contains spaces.
    final result = await _adbShell(
      _runAs(
        "find ${_q(base)} -mindepth 1 -exec stat -c '%F|%s|%n' {} +",
      ),
    );
    if (result.exitCode != 0) {
      throw AppDataExplorerException(_adbError('lsRecursive', result));
    }
    final basePrefix = base == '.' ? './' : '$base/';
    final entries = <Entry>[];
    for (final line in (result.stdout as String).split('\n')) {
      if (line.isEmpty) continue;
      final p1 = line.indexOf('|');
      if (p1 < 0) continue;
      final p2 = line.indexOf('|', p1 + 1);
      if (p2 < 0) continue;
      final type = line.substring(0, p1);
      final size = int.tryParse(line.substring(p1 + 1, p2));
      var name = line.substring(p2 + 1);
      if (name.startsWith(basePrefix)) {
        name = name.substring(basePrefix.length);
      } else if (name.startsWith('./')) {
        name = name.substring(2);
      }
      if (name.isEmpty) continue;
      final isDirectory = type == 'directory';
      entries.add(
        Entry(name, isDir: isDirectory, sizeBytes: isDirectory ? null : size),
      );
    }
    return entries;
  }

  @override
  Future<void> rm(String relPath) async {
    if (relPath.isEmpty) {
      throw const AppDataExplorerException('refuse to rm empty path');
    }
    final result = await _adbShell(_runAs('rm -f ${_q(relPath)}'));
    if (result.exitCode != 0) {
      throw AppDataExplorerException(_adbError('rm', result));
    }
  }

  @override
  Future<void> clearDir(String relDir) async {
    if (relDir.isEmpty) {
      throw const AppDataExplorerException('refuse to clear container root');
    }
    final result = await _adbShell(_runAs('find ${_q(relDir)} -mindepth 1 -delete'));
    if (result.exitCode != 0) {
      throw AppDataExplorerException(_adbError('clear', result));
    }
  }

  @override
  Future<void> pull(String remoteRelPath, String localPath) async {
    final adb = resolveAdbPath() ?? 'adb';
    final proc = await Process.start(
      adb,
      ['-s', serial, 'exec-out', 'run-as', pkg, 'cat', remoteRelPath],
    );
    final sink = File(localPath).openWrite();
    final stderrBuffer = StringBuffer();
    final stderrFut = proc.stderr.transform(utf8.decoder).forEach(stderrBuffer.write);
    await proc.stdout.pipe(sink);
    final ec = await proc.exitCode;
    await stderrFut;
    if (ec != 0) {
      throw AppDataExplorerException(
        'pull failed: ${stderrBuffer.toString().trim()}',
      );
    }
  }

  @override
  Future<void> push(String localPath, String remoteRelPath) async {
    if (remoteRelPath.isEmpty) {
      throw const AppDataExplorerException('refuse to push to empty path');
    }
    // adb push can't write directly into /data/data/<pkg>/. Hand off
    // through /data/local/tmp/ (world-readable so the app user can read
    // it via run-as), then cp into place, then clean up.
    final adb = resolveAdbPath() ?? 'adb';
    final base = remoteRelPath.split('/').last;
    final tmpRemote = '/data/local/tmp/dbscope_push_${DateTime.now().microsecondsSinceEpoch}_$base';
    final r1 = await Process.run(adb, ['-s', serial, 'push', localPath, tmpRemote]);
    if (r1.exitCode != 0) {
      throw AppDataExplorerException(
        'adb push failed (exit ${r1.exitCode}): ${(r1.stderr as String).trim()}',
      );
    }
    try {
      final r2 = await _adbShell(_runAs('cp ${_q(tmpRemote)} ${_q(remoteRelPath)}'));
      if (r2.exitCode != 0) {
        throw AppDataExplorerException(_adbError('push-cp', r2));
      }
    } finally {
      await Process.run(adb, ['-s', serial, 'shell', 'rm', '-f', tmpRemote]);
    }
  }

  static String _adbError(String op, ProcessResult result) {
    final out = (result.stdout as String).trim();
    final error = (result.stderr as String).trim();
    return 'adb $op failed (exit ${result.exitCode}): ${[
      error,
      out,
    ].where((part) => part.isNotEmpty).join(' | ')}';
  }

  static List<Entry> _parseLsLap(String output) {
    final entries = <Entry>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('total ')) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 8) continue;
      final perms = parts[0];
      if (perms.isEmpty) continue;
      final size = int.tryParse(parts[4]);
      var name = parts.sublist(7).join(' ');
      var isDirectory = perms.startsWith('d');
      if (name.endsWith('/')) {
        isDirectory = true;
        name = name.substring(0, name.length - 1);
      }
      if (name.contains(' -> ')) name = name.split(' -> ').first;
      if (name.isEmpty) continue;
      entries.add(Entry(name, isDir: isDirectory, sizeBytes: size));
    }
    return entries;
  }

  static String _q(String text) {
    if (RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(text)) return text;
    return "'${text.replaceAll("'", r"'\''")}'";
  }
}

class AndroidDeviceInfo {
  AndroidDeviceInfo({required this.serial, required this.state, this.model});
  final String serial;
  final String state; // 'device', 'unauthorized', 'offline', ...
  final String? model;
}

class AndroidDetectionResult {
  AndroidDetectionResult({required this.devices, this.hint});
  final List<AndroidDeviceInfo> devices;
  final String? hint;
}

/// Detects Android devices. `hint` is non-null when something needs surfacing
/// (adb missing, device unauthorized/offline, ...).
Future<AndroidDetectionResult> detectAndroidDevices() async {
  final adb = resolveAdbPath();
  if (adb == null) {
    return AndroidDetectionResult(
      devices: const [],
      hint: 'adb not found on PATH or in standard SDK locations. Install Android '
          'platform-tools or set ANDROID_HOME. Try: `brew install android-platform-tools` '
          r'or symlink $HOME/Library/Android/sdk/platform-tools/adb into PATH.',
    );
  }
  ProcessResult r;
  try {
    r = await Process.run(adb, ['devices', '-l']);
  } on ProcessException catch (e) {
    return AndroidDetectionResult(
      devices: const [],
      hint: 'failed to run $adb: $e',
    );
  }
  if (r.exitCode != 0) {
    return AndroidDetectionResult(
      devices: const [],
      hint: 'adb devices failed: ${(r.stderr as String).trim()}',
    );
  }
  final out = r.stdout as String;
  final all = <AndroidDeviceInfo>[];
  for (final line in out.split('\n').skip(1)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final match = RegExp(r'^(\S+)\s+(\S+)(.*)$').firstMatch(trimmed);
    if (match == null) continue;
    final state = match.group(2)!;
    final rest = match.group(3) ?? '';
    final modelMatch = RegExp(r'model:(\S+)').firstMatch(rest);
    all.add(
      AndroidDeviceInfo(
        serial: match.group(1)!,
        state: state,
        model: modelMatch?.group(1),
      ),
    );
  }
  final usable = all.where((device) => device.state == 'device').toList();
  String? hint;
  final problem = all.where((device) => device.state != 'device').toList();
  if (problem.isNotEmpty) {
    hint =
        'android device(s) not ready: ${problem.map((device) => '${device.serial} (${device.state})').join(', ')}. '
        'Unlock the phone and accept the USB-debugging prompt.';
  }
  return AndroidDetectionResult(devices: usable, hint: hint);
}

/// Lists third-party packages on the device. Pass [includeSystem] to also
/// include system packages.
Future<List<String>> listAndroidPackages(
  String serial, {
  bool includeSystem = false,
}) async {
  final adb = resolveAdbPath() ?? 'adb';
  final args = ['-s', serial, 'shell', 'pm', 'list', 'packages'];
  if (!includeSystem) args.add('-3');
  final result = await Process.run(adb, args);
  if (result.exitCode != 0) return const [];
  final pkgs = <String>[];
  for (final line in (result.stdout as String).split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('package:')) {
      pkgs.add(trimmed.substring('package:'.length));
    }
  }
  pkgs.sort();
  return pkgs;
}

/// Probes whether `run-as <pkg>` works on the device (i.e. the APK is
/// debuggable).
Future<bool> isAndroidPackageDebuggable(String serial, String pkg) async {
  final adb = resolveAdbPath();
  if (adb == null) return false;
  final result = await Process.run(adb, ['-s', serial, 'shell', 'run-as', pkg, 'true']);
  return result.exitCode == 0;
}

// ---------------------------------------------------------------------------
// iOS backend (via xcrun devicectl)
// ---------------------------------------------------------------------------

class IosBackend extends Backend {
  IosBackend({
    required this.deviceId,
    required this.bundleId,
    this.deviceName,
    this.onProgress,
  });

  final String deviceId; // devicectl `identifier` field
  final String bundleId;
  final String? deviceName;

  /// Optional callback so UIs can surface long-running operations (e.g. the
  /// iOS `rm` pull-modify-push roundtrip). The CLI hooks this up to stdout.
  final void Function(String message)? onProgress;

  @override
  String get deviceLabel => 'ios ${deviceName ?? deviceId}';

  @override
  String get appLabel => bundleId;

  Future<Map<String, dynamic>> _devicectlJson(List<String> args) async {
    Object lastErr = const AppDataExplorerException('devicectl failed');
    var lastStack = StackTrace.current;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _devicectlJsonOnce(args);
      } catch (e, st) {
        lastErr = e;
        lastStack = st;
        final message = e.toString();
        final transient = message.contains('device disconnected') ||
            message.contains('StreamingAction') ||
            message.contains("Couldn't get the message");
        if (!transient) rethrow;
      }
    }
    Error.throwWithStackTrace(lastErr, lastStack);
  }

  Future<Map<String, dynamic>> _devicectlJsonOnce(List<String> args) async {
    final tempFile = await File(
      '${Directory.systemTemp.path}/devicectl-${DateTime.now().microsecondsSinceEpoch}.json',
    ).create();
    try {
      final result = await Process.run('xcrun', [
        'devicectl',
        ...args,
        '--json-output',
        tempFile.path,
      ]);
      if (!tempFile.existsSync()) {
        throw AppDataExplorerException(
          'devicectl produced no JSON. stderr: ${(result.stderr as String).trim()}',
        );
      }
      final body = await tempFile.readAsString();
      if (body.isEmpty) {
        throw AppDataExplorerException(
          'devicectl wrote empty JSON. exit=${result.exitCode} stderr=${(result.stderr as String).trim()}',
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final outcome = (json['info'] as Map?)?['outcome'];
      if (outcome != 'success') {
        final errs = json['error'] ?? json['result'] ?? body;
        throw AppDataExplorerException(
          'devicectl failed (${outcome ?? 'no outcome'}): $errs',
        );
      }
      return json;
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }

  @override
  Future<List<Entry>> ls(String relPath) async {
    final args = <String>[
      'device',
      'info',
      'files',
      '--device',
      deviceId,
      '--domain-type',
      'appDataContainer',
      '--domain-identifier',
      bundleId,
    ];
    if (relPath.isNotEmpty) args.addAll(['--subdirectory', relPath]);
    final json = await _devicectlJson(args);
    return _parseFiles(json);
  }

  @override
  Future<List<Entry>> lsRecursive(String relPath) async {
    // devicectl already returns a flat list of all descendants.
    final args = <String>[
      'device',
      'info',
      'files',
      '--device',
      deviceId,
      '--domain-type',
      'appDataContainer',
      '--domain-identifier',
      bundleId,
    ];
    if (relPath.isNotEmpty) args.addAll(['--subdirectory', relPath]);
    final json = await _devicectlJson(args);
    return _parseFiles(json, directChildrenOnly: false);
  }

  @override
  Future<void> rm(String relPath) async {
    if (relPath.isEmpty) {
      throw const AppDataExplorerException('refuse to rm empty path');
    }
    final segments = _splitPath(relPath);
    if (segments.isEmpty) throw const AppDataExplorerException('invalid path');
    final fileName = segments.last;
    final parentRel =
        segments.length == 1 ? '' : segments.sublist(0, segments.length - 1).join('/');

    onProgress?.call('iOS rm: downloading parent dir ${parentRel.isEmpty ? '<root>' : parentRel}/ '
        '(can be slow for large dirs)...');
    final tmpRoot = await Directory.systemTemp.createTemp('explorer_rm_');
    try {
      final localCopy = Directory('${tmpRoot.path}/parent');
      await localCopy.create();
      await _devicectlJson([
        'device',
        'copy',
        'from',
        '--device',
        deviceId,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        bundleId,
        '--source',
        if (parentRel.isEmpty) '.' else parentRel,
        '--destination',
        localCopy.path,
      ]);
      final pulled = await _findPulledRoot(
        localCopy,
        expectedName: parentRel.isEmpty ? null : segments[segments.length - 2],
      );
      final target = File('${pulled.path}/$fileName');
      if (target.existsSync()) {
        await target.delete();
      } else {
        final dirTarget = Directory('${pulled.path}/$fileName');
        if (dirTarget.existsSync()) {
          await dirTarget.delete(recursive: true);
        } else {
          throw AppDataExplorerException(
            'rm: $relPath not found in pulled snapshot',
          );
        }
      }
      await _devicectlJson([
        'device',
        'copy',
        'to',
        '--device',
        deviceId,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        bundleId,
        '--source',
        pulled.path,
        '--destination',
        if (parentRel.isEmpty) '.' else parentRel,
        '--remove-existing-content',
        'true',
      ]);
    } finally {
      try {
        await tmpRoot.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> clearDir(String relDir) async {
    if (relDir.isEmpty) {
      throw const AppDataExplorerException('refuse to clear container root');
    }
    final tempDirectory = await Directory.systemTemp.createTemp('explorer_clear_');
    try {
      await _devicectlJson([
        'device',
        'copy',
        'to',
        '--device',
        deviceId,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        bundleId,
        '--source',
        tempDirectory.path,
        '--destination',
        relDir,
        '--remove-existing-content',
        'true',
      ]);
    } finally {
      try {
        await tempDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> pull(String remoteRelPath, String localPath) async {
    await _devicectlJson([
      'device',
      'copy',
      'from',
      '--device',
      deviceId,
      '--domain-type',
      'appDataContainer',
      '--domain-identifier',
      bundleId,
      '--source',
      remoteRelPath,
      '--destination',
      localPath,
    ]);
  }

  @override
  Future<void> push(String localPath, String remoteRelPath) async {
    if (remoteRelPath.isEmpty) {
      throw const AppDataExplorerException('refuse to push to empty path');
    }
    await _devicectlJson([
      'device',
      'copy',
      'to',
      '--device',
      deviceId,
      '--domain-type',
      'appDataContainer',
      '--domain-identifier',
      bundleId,
      '--source',
      localPath,
      '--destination',
      remoteRelPath,
      '--remove-existing-content',
      'true',
    ]);
  }

  static List<String> _splitPath(String path) =>
      path.split('/').where((segment) => segment.isNotEmpty).toList();

  static Future<Directory> _findPulledRoot(
    Directory localCopy, {
    String? expectedName,
  }) async {
    final entries = await localCopy.list().toList();
    if (entries.length == 1 && entries.first is Directory) {
      return entries.first as Directory;
    }
    if (expectedName != null) {
      for (final e in entries) {
        if (e is Directory && e.path.endsWith('/$expectedName')) return e;
      }
    }
    return localCopy;
  }

  /// Parses `devicectl device info files` JSON. devicectl returns a flat
  /// list of descendants with relativePath strings. When
  /// [directChildrenOnly] is true, filters to entries with no '/' in
  /// relativePath - the immediate children of the queried root.
  static List<Entry> _parseFiles(
    Map<String, dynamic> json, {
    bool directChildrenOnly = true,
  }) {
    final result = json['result'];
    if (result is! Map<String, dynamic>) return const [];
    final filesAny = result['files'];
    if (filesAny is! List) return const [];
    final entries = <Entry>[];
    for (final file in filesAny) {
      if (file is! Map) continue;
      final relPath = (file['relativePath'] ?? file['name'])?.toString();
      if (relPath == null || relPath.isEmpty) continue;
      if (directChildrenOnly && relPath.contains('/')) continue;
      final resources = file['resources'];
      final isDirectory = resources is Map && resources['isDirectory'] == true;
      final isLink = resources is Map && resources['isSymbolicLink'] == true;
      final metadata = file['metadata'];
      final sizeRaw = (metadata is Map) ? metadata['size'] : null;
      final size = sizeRaw is num ? sizeRaw.toInt() : null;
      entries.add(
        Entry(
          isLink ? '$relPath@' : relPath,
          isDir: isDirectory,
          sizeBytes: size,
        ),
      );
    }
    return entries;
  }
}

class IosDeviceInfo {
  IosDeviceInfo({required this.identifier, required this.name});
  final String identifier;
  final String name;
}

Future<List<IosDeviceInfo>> detectIosDevices() async {
  final tempFile = await File(
    '${Directory.systemTemp.path}/explorer-devs-${DateTime.now().microsecondsSinceEpoch}.json',
  ).create();
  try {
    final result = await Process.run(
      'xcrun',
      ['devicectl', 'list', 'devices', '--json-output', tempFile.path],
    );
    if (!tempFile.existsSync()) return const [];
    final body = await tempFile.readAsString();
    if (body.isEmpty) return const [];
    final json = jsonDecode(body) as Map<String, dynamic>;
    if ((json['info'] as Map?)?['outcome'] != 'success') return const [];
    final devs = (json['result'] as Map?)?['devices'];
    if (devs is! List) return const [];
    final out = <IosDeviceInfo>[];
    for (final device in devs) {
      if (device is! Map) continue;
      final id = device['identifier']?.toString();
      if (id == null) continue;
      final name = (device['deviceProperties'] as Map?)?['name']?.toString() ?? id;
      final tunnel = (device['connectionProperties'] as Map?)?['tunnelState']?.toString();
      final pairing = (device['connectionProperties'] as Map?)?['pairingState']?.toString();
      if (pairing != 'paired' || tunnel == 'unavailable') continue;
      out.add(IosDeviceInfo(identifier: id, name: name));
    }
    if (result.exitCode != 0 && out.isEmpty) return const [];
    return out;
  } catch (_) {
    return const [];
  } finally {
    try {
      await tempFile.delete();
    } catch (_) {}
  }
}

class IosApp {
  IosApp({required this.bundleId, this.name});
  final String bundleId;
  final String? name;
  @override
  String toString() => name == null ? bundleId : '$bundleId ($name)';
}

/// Lists installed developer apps via devicectl. Pass [includeSystem] to
/// include built-in iOS apps too. Throws with the devicectl error on failure.
Future<List<IosApp>> listIosApps(
  String deviceId, {
  bool includeSystem = false,
}) async {
  final tempFile = await File(
    '${Directory.systemTemp.path}/explorer-apps-${DateTime.now().microsecondsSinceEpoch}.json',
  ).create();
  try {
    final args = [
      'devicectl',
      'device',
      'info',
      'apps',
      '--device',
      deviceId,
      '--json-output',
      tempFile.path,
    ];
    if (includeSystem) args.add('--include-all-apps');
    final result = await Process.run('xcrun', args);
    if (!tempFile.existsSync() || tempFile.lengthSync() == 0) {
      throw AppDataExplorerException(
        'devicectl produced no JSON (exit ${result.exitCode}). stderr: ${(result.stderr as String).trim()}',
      );
    }
    final body = await tempFile.readAsString();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final outcome = (json['info'] as Map?)?['outcome'];
    if (outcome != 'success') {
      final error = json['error'] ?? body;
      throw AppDataExplorerException(
        'devicectl failed (${outcome ?? 'no outcome'}): $error',
      );
    }
    final apps = (json['result'] as Map?)?['apps'];
    if (apps is! List) return const [];
    final out = <IosApp>[];
    for (final app in apps) {
      if (app is! Map) continue;
      final id = app['bundleIdentifier']?.toString();
      if (id == null) continue;
      final name = (app['name'] ?? app['displayName'])?.toString();
      out.add(IosApp(bundleId: id, name: name));
    }
    out.sort((a, b) => a.bundleId.compareTo(b.bundleId));
    return out;
  } finally {
    try {
      await tempFile.delete();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Reachability + has-data probes (for UIs that want to hide noise)
// ---------------------------------------------------------------------------

/// How long to wait for a phone to answer "are you there?" before treating
/// it as unreachable.
const _kReachabilityTimeout = Duration(seconds: 3);

/// How long to wait while listing an app's files to see whether it has any
/// data. Slower than the reachability check because it reads the device.
const _kHasDataTimeout = Duration(seconds: 5);

/// Returns true when the iOS device responds to a `devicectl info details`
/// call within [timeout]. devicectl `list devices` returns every paired
/// device including ones that are nowhere nearby, so this probe is needed
/// if you want to show only currently-reachable devices.
Future<bool> isIosDeviceReachable(
  String deviceId, {
  Duration timeout = _kReachabilityTimeout,
}) async {
  Process? proc;
  final tempFile = await File(
    '${Directory.systemTemp.path}/explorer-reach-${DateTime.now().microsecondsSinceEpoch}.json',
  ).create();
  try {
    proc = await Process.start('xcrun', [
      'devicectl',
      'device',
      'info',
      'details',
      '--device',
      deviceId,
      '--json-output',
      tempFile.path,
    ]);
    final ec = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc?.kill();
        return -1;
      },
    );
    return ec == 0;
  } catch (_) {
    return false;
  } finally {
    try {
      await tempFile.delete();
    } catch (_) {}
  }
}

/// Returns true when the iOS app's data container has at least one
/// non-system file. The metadata.plist that iOS auto-creates is ignored.
Future<bool> iosAppHasData(
  String deviceId,
  String bundleId, {
  Duration timeout = _kHasDataTimeout,
}) async {
  try {
    final backend = IosBackend(deviceId: deviceId, bundleId: bundleId);
    final entries = await backend.ls('').timeout(timeout);
    final real = entries.where(
      (e) => !e.name.startsWith('.com.apple.mobile_container_manager'),
    );
    return real.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Returns true when `run-as <pkg>` succeeds AND the data dir has at least
/// one file. Always returns false on non-debuggable APKs.
Future<bool> androidAppHasData(
  String serial,
  String pkg, {
  Duration timeout = _kHasDataTimeout,
}) async {
  final adb = resolveAdbPath();
  if (adb == null) return false;
  try {
    final result = await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'run-as',
      pkg,
      'sh',
      '-c',
      'find . -mindepth 1 -type f 2>/dev/null | head -1',
    ]).timeout(timeout);
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

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

// ---------------------------------------------------------------------------
// adb discovery
// ---------------------------------------------------------------------------

String? _adbPath;

/// Resolves `adb` from `$PATH`, then from common Android SDK locations.
/// Returns null if not found anywhere.
String? resolveAdbPath() {
  if (_adbPath != null) return _adbPath;
  try {
    final r = Process.runSync('command', ['-v', 'adb'], runInShell: true);
    if (r.exitCode == 0) {
      final p = (r.stdout as String).trim();
      if (p.isNotEmpty && File(p).existsSync()) {
        return _adbPath = p;
      }
    }
  } catch (_) {}
  final env = Platform.environment;
  final candidates = <String>[
    if (env['ANDROID_HOME'] != null)
      '${env['ANDROID_HOME']}/platform-tools/adb',
    if (env['ANDROID_SDK_ROOT'] != null)
      '${env['ANDROID_SDK_ROOT']}/platform-tools/adb',
    '${env['HOME']}/Library/Android/sdk/platform-tools/adb',
    '${env['HOME']}/Android/Sdk/platform-tools/adb',
    '/usr/local/bin/adb',
    '/opt/homebrew/bin/adb',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return _adbPath = c;
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
  String get deviceLabel =>
      'android $serial${model == null ? '' : ' ($model)'}';

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
    final r = await _adbShell(_runAs('ls -lAp ${_q(target)}'));
    if (r.exitCode != 0) throw _adbError('ls', r);
    return _parseLsLap(r.stdout as String);
  }

  @override
  Future<List<Entry>> lsRecursive(String relPath) async {
    final base = relPath.isEmpty ? '.' : relPath;
    // Some Android toybox builds reject `find -printf`, so use the more
    // portable `find ... -exec stat ... {} +`. %F is the human-readable file
    // type ("regular file", "directory", "symbolic link"), %s is size, %n is
    // the full path the matcher saw. We use '|' as the separator since %F
    // contains spaces.
    final r = await _adbShell(
      _runAs(
        "find ${_q(base)} -mindepth 1 -exec stat -c '%F|%s|%n' {} +",
      ),
    );
    if (r.exitCode != 0) throw _adbError('lsRecursive', r);
    final basePrefix = base == '.' ? './' : '$base/';
    final entries = <Entry>[];
    for (final line in (r.stdout as String).split('\n')) {
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
      final isDir = type == 'directory';
      entries.add(Entry(name, isDir: isDir, sizeBytes: isDir ? null : size));
    }
    return entries;
  }

  @override
  Future<void> rm(String relPath) async {
    if (relPath.isEmpty) throw 'refuse to rm empty path';
    final r = await _adbShell(_runAs('rm -f ${_q(relPath)}'));
    if (r.exitCode != 0) throw _adbError('rm', r);
  }

  @override
  Future<void> clearDir(String relDir) async {
    if (relDir.isEmpty) throw 'refuse to clear container root';
    final r = await _adbShell(_runAs('find ${_q(relDir)} -mindepth 1 -delete'));
    if (r.exitCode != 0) throw _adbError('clear', r);
  }

  @override
  Future<void> pull(String remoteRelPath, String localPath) async {
    final adb = resolveAdbPath() ?? 'adb';
    final proc = await Process.start(
      adb,
      ['-s', serial, 'exec-out', 'run-as', pkg, 'cat', remoteRelPath],
    );
    final sink = File(localPath).openWrite();
    final stderrBuf = StringBuffer();
    final stderrFut =
        proc.stderr.transform(utf8.decoder).forEach(stderrBuf.write);
    await proc.stdout.pipe(sink);
    final ec = await proc.exitCode;
    await stderrFut;
    if (ec != 0) throw 'pull failed: ${stderrBuf.toString().trim()}';
  }

  @override
  Future<void> push(String localPath, String remoteRelPath) async {
    if (remoteRelPath.isEmpty) throw 'refuse to push to empty path';
    // adb push can't write directly into /data/data/<pkg>/. Hand off
    // through /data/local/tmp/ (world-readable so the app user can read
    // it via run-as), then cp into place, then clean up.
    final adb = resolveAdbPath() ?? 'adb';
    final base = remoteRelPath.split('/').last;
    final tmpRemote =
        '/data/local/tmp/dbscope_push_${DateTime.now().microsecondsSinceEpoch}_$base';
    final r1 =
        await Process.run(adb, ['-s', serial, 'push', localPath, tmpRemote]);
    if (r1.exitCode != 0) {
      throw 'adb push failed (exit ${r1.exitCode}): ${(r1.stderr as String).trim()}';
    }
    try {
      final r2 =
          await _adbShell(_runAs('cp ${_q(tmpRemote)} ${_q(remoteRelPath)}'));
      if (r2.exitCode != 0) throw _adbError('push-cp', r2);
    } finally {
      await Process.run(adb, ['-s', serial, 'shell', 'rm', '-f', tmpRemote]);
    }
  }

  static String _adbError(String op, ProcessResult r) {
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    return 'adb $op failed (exit ${r.exitCode}): ${[
      err,
      out,
    ].where((s) => s.isNotEmpty).join(' | ')}';
  }

  static List<Entry> _parseLsLap(String output) {
    final entries = <Entry>[];
    for (final line in output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('total ')) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 8) continue;
      final perms = parts[0];
      if (perms.isEmpty) continue;
      final size = int.tryParse(parts[4]);
      var name = parts.sublist(7).join(' ');
      var isDir = perms.startsWith('d');
      if (name.endsWith('/')) {
        isDir = true;
        name = name.substring(0, name.length - 1);
      }
      if (name.contains(' -> ')) name = name.split(' -> ').first;
      if (name.isEmpty) continue;
      entries.add(Entry(name, isDir: isDir, sizeBytes: size));
    }
    return entries;
  }

  static String _q(String s) {
    if (RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
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
      hint:
          'adb not found on PATH or in standard SDK locations. Install Android '
          'platform-tools or set ANDROID_HOME. Try: `brew install android-platform-tools` '
          'or symlink \$HOME/Library/Android/sdk/platform-tools/adb into PATH.',
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
    final t = line.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^(\S+)\s+(\S+)(.*)$').firstMatch(t);
    if (m == null) continue;
    final state = m.group(2)!;
    final rest = m.group(3) ?? '';
    final modelMatch = RegExp(r'model:(\S+)').firstMatch(rest);
    all.add(
      AndroidDeviceInfo(
        serial: m.group(1)!,
        state: state,
        model: modelMatch?.group(1),
      ),
    );
  }
  final usable = all.where((d) => d.state == 'device').toList();
  String? hint;
  final problem = all.where((d) => d.state != 'device').toList();
  if (problem.isNotEmpty) {
    hint =
        'android device(s) not ready: ${problem.map((d) => '${d.serial} (${d.state})').join(', ')}. '
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
  final r = await Process.run(adb, args);
  if (r.exitCode != 0) return const [];
  final pkgs = <String>[];
  for (final line in (r.stdout as String).split('\n')) {
    final t = line.trim();
    if (t.startsWith('package:')) pkgs.add(t.substring('package:'.length));
  }
  pkgs.sort();
  return pkgs;
}

/// Probes whether `run-as <pkg>` works on the device (i.e. the APK is
/// debuggable).
Future<bool> isAndroidPackageDebuggable(String serial, String pkg) async {
  final adb = resolveAdbPath();
  if (adb == null) return false;
  final r =
      await Process.run(adb, ['-s', serial, 'shell', 'run-as', pkg, 'true']);
  return r.exitCode == 0;
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
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _devicectlJsonOnce(args);
      } catch (e) {
        lastErr = e;
        final msg = e.toString();
        final transient = msg.contains('device disconnected') ||
            msg.contains('StreamingAction') ||
            msg.contains('Couldn\'t get the message');
        if (!transient) rethrow;
      }
    }
    throw lastErr ?? 'devicectl failed';
  }

  Future<Map<String, dynamic>> _devicectlJsonOnce(List<String> args) async {
    final tmp = await File(
      '${Directory.systemTemp.path}/devicectl-${DateTime.now().microsecondsSinceEpoch}.json',
    ).create();
    try {
      final r = await Process.run('xcrun', [
        'devicectl',
        ...args,
        '--json-output',
        tmp.path,
      ]);
      if (!await tmp.exists()) {
        throw 'devicectl produced no JSON. stderr: ${(r.stderr as String).trim()}';
      }
      final body = await tmp.readAsString();
      if (body.isEmpty) {
        throw 'devicectl wrote empty JSON. exit=${r.exitCode} stderr=${(r.stderr as String).trim()}';
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final outcome = (json['info'] as Map?)?['outcome'];
      if (outcome != 'success') {
        final errs = json['error'] ?? json['result'] ?? body;
        throw 'devicectl failed (${outcome ?? 'no outcome'}): $errs';
      }
      return json;
    } finally {
      try {
        await tmp.delete();
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
    return _parseFiles(json, directChildrenOnly: true);
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
    if (relPath.isEmpty) throw 'refuse to rm empty path';
    final segments = _splitPath(relPath);
    if (segments.isEmpty) throw 'invalid path';
    final fileName = segments.last;
    final parentRel = segments.length == 1
        ? ''
        : segments.sublist(0, segments.length - 1).join('/');

    onProgress?.call(
        'iOS rm: downloading parent dir ${parentRel.isEmpty ? '<root>' : parentRel}/ '
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
        parentRel.isEmpty ? '.' : parentRel,
        '--destination',
        localCopy.path,
      ]);
      final pulled = await _findPulledRoot(
        localCopy,
        expectedName: parentRel.isEmpty ? null : segments[segments.length - 2],
      );
      final target = File('${pulled.path}/$fileName');
      if (await target.exists()) {
        await target.delete();
      } else {
        final dirTarget = Directory('${pulled.path}/$fileName');
        if (await dirTarget.exists()) {
          await dirTarget.delete(recursive: true);
        } else {
          throw 'rm: $relPath not found in pulled snapshot';
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
        parentRel.isEmpty ? '.' : parentRel,
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
    if (relDir.isEmpty) throw 'refuse to clear container root';
    final tmp = await Directory.systemTemp.createTemp('explorer_clear_');
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
        tmp.path,
        '--destination',
        relDir,
        '--remove-existing-content',
        'true',
      ]);
    } finally {
      try {
        await tmp.delete(recursive: true);
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
    if (remoteRelPath.isEmpty) throw 'refuse to push to empty path';
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

  static List<String> _splitPath(String p) =>
      p.split('/').where((s) => s.isNotEmpty).toList();

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
    for (final f in filesAny) {
      if (f is! Map) continue;
      final relPath = (f['relativePath'] ?? f['name'])?.toString();
      if (relPath == null || relPath.isEmpty) continue;
      if (directChildrenOnly && relPath.contains('/')) continue;
      final resources = f['resources'];
      final isDir = (resources is Map && resources['isDirectory'] == true);
      final isLink = (resources is Map && resources['isSymbolicLink'] == true);
      final metadata = f['metadata'];
      final sizeRaw = (metadata is Map) ? metadata['size'] : null;
      final size = sizeRaw is num ? sizeRaw.toInt() : null;
      entries.add(
        Entry(
          isLink ? '$relPath@' : relPath,
          isDir: isDir,
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
  final tmp = await File(
    '${Directory.systemTemp.path}/explorer-devs-${DateTime.now().microsecondsSinceEpoch}.json',
  ).create();
  try {
    final r = await Process.run(
      'xcrun',
      ['devicectl', 'list', 'devices', '--json-output', tmp.path],
    );
    if (!await tmp.exists()) return const [];
    final body = await tmp.readAsString();
    if (body.isEmpty) return const [];
    final json = jsonDecode(body) as Map<String, dynamic>;
    if ((json['info'] as Map?)?['outcome'] != 'success') return const [];
    final devs = (json['result'] as Map?)?['devices'];
    if (devs is! List) return const [];
    final out = <IosDeviceInfo>[];
    for (final d in devs) {
      if (d is! Map) continue;
      final id = d['identifier']?.toString();
      if (id == null) continue;
      final name = (d['deviceProperties'] as Map?)?['name']?.toString() ?? id;
      final tunnel =
          (d['connectionProperties'] as Map?)?['tunnelState']?.toString();
      final pairing =
          (d['connectionProperties'] as Map?)?['pairingState']?.toString();
      if (pairing != 'paired' || tunnel == 'unavailable') continue;
      out.add(IosDeviceInfo(identifier: id, name: name));
    }
    if (r.exitCode != 0 && out.isEmpty) return const [];
    return out;
  } catch (_) {
    return const [];
  } finally {
    try {
      await tmp.delete();
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
  final tmp = await File(
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
      tmp.path,
    ];
    if (includeSystem) args.add('--include-all-apps');
    final r = await Process.run('xcrun', args);
    if (!await tmp.exists() || (await tmp.length()) == 0) {
      throw 'devicectl produced no JSON (exit ${r.exitCode}). stderr: ${(r.stderr as String).trim()}';
    }
    final body = await tmp.readAsString();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final outcome = (json['info'] as Map?)?['outcome'];
    if (outcome != 'success') {
      final err = json['error'] ?? body;
      throw 'devicectl failed (${outcome ?? 'no outcome'}): $err';
    }
    final apps = (json['result'] as Map?)?['apps'];
    if (apps is! List) return const [];
    final out = <IosApp>[];
    for (final a in apps) {
      if (a is! Map) continue;
      final id = a['bundleIdentifier']?.toString();
      if (id == null) continue;
      final name = (a['name'] ?? a['displayName'])?.toString();
      out.add(IosApp(bundleId: id, name: name));
    }
    out.sort((a, b) => a.bundleId.compareTo(b.bundleId));
    return out;
  } finally {
    try {
      await tmp.delete();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Reachability + has-data probes (for UIs that want to hide noise)
// ---------------------------------------------------------------------------

/// Returns true when the iOS device responds to a `devicectl info details`
/// call within [timeout]. devicectl `list devices` returns every paired
/// device including ones that are nowhere nearby, so this probe is needed
/// if you want to show only currently-reachable devices.
Future<bool> isIosDeviceReachable(
  String deviceId, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  Process? proc;
  final tmp = await File(
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
      tmp.path,
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
      await tmp.delete();
    } catch (_) {}
  }
}

/// Returns true when the iOS app's data container has at least one
/// non-system file. The metadata.plist that iOS auto-creates is ignored.
Future<bool> iosAppHasData(
  String deviceId,
  String bundleId, {
  Duration timeout = const Duration(seconds: 5),
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
  Duration timeout = const Duration(seconds: 5),
}) async {
  final adb = resolveAdbPath();
  if (adb == null) return false;
  try {
    final r = await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'run-as',
      pkg,
      'sh',
      '-c',
      'find . -mindepth 1 -type f 2>/dev/null | head -1',
    ]).timeout(timeout);
    return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

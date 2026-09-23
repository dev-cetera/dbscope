// Interactive CLI front-end for the app_data_explorer library.
//
// Picks a device + app, then:
// - Android: drops you into a real `adb shell` (with `run-as <pkg>` when
// debuggable) - you use the device's own ls/grep/find/cat/du/etc.
// - iOS: opens a small file-API REPL on top of `xcrun devicectl`
// (devicectl has no shell, so we wrap its file ops).
//
// All reusable logic lives in `package:app_data_explorer/app_data_explorer.dart`
// so a future UI (e.g. local session viewer) can import the same backends.

import 'dart:async';
import 'dart:io';

import 'package:app_data_explorer/app_data_explorer.dart';

Future<void> main(List<String> argv) async {
  stdout.writeln('Flutter App Data Explorer');
  stdout.writeln('');

  final backend = await pickBackend();
  if (backend == null) return;

  if (backend is AndroidBackend) {
    exitCode = await dropIntoAdbShell(backend.serial, backend.pkg);
    return;
  }

  await IosRepl(backend as IosBackend).run();
}

// ---------------------------------------------------------------------------
// Device + app selection (CLI prompts)
// ---------------------------------------------------------------------------

Future<Backend?> pickBackend() async {
  stdout.write('Scanning devices...\n');
  final androidFut = detectAndroidDevices();
  final iosFut = detectIosDevices();
  final androidResult = await androidFut;
  final ioses = await iosFut;
  final androids = androidResult.devices;

  if (androidResult.hint != null) {
    stdout.writeln('Android: ${androidResult.hint}');
  }

  if (androids.isEmpty && ioses.isEmpty) {
    stderr.writeln('No connected devices found.');
    if (androidResult.hint == null) {
      stderr.writeln(
        ' Android: ensure `adb devices` shows the phone as `device` (not unauthorized/offline).',
      );
    }
    stderr.writeln(
      ' iOS: `xcrun devicectl list devices` should show a paired device.',
    );
    return null;
  }

  final options = <({String label, Future<Backend?> Function() pick})>[];
  for (final d in androids) {
    options.add(
      (
        label: 'android ${d.serial}${d.model == null ? '' : ' (${d.model})'}',
        pick: () => _pickAndroidApp(d.serial, d.model),
      ),
    );
  }
  for (final d in ioses) {
    options.add(
      (
        label: 'ios ${d.name} (${d.identifier})',
        pick: () => _pickIosApp(d.identifier, d.name),
      ),
    );
  }

  int idx = 0;
  if (options.length > 1) {
    stdout.writeln('\nConnected devices:');
    for (var i = 0; i < options.length; i++) {
      stdout.writeln(' [$i] ${options[i].label}');
    }
    idx = _promptIndex('Pick a device', options.length);
    if (idx < 0) return null;
  } else {
    stdout.writeln('Device: ${options[0].label}');
  }
  return options[idx].pick();
}

Future<Backend?> _pickAndroidApp(String serial, String? model) async {
  stdout.write('Listing installed third-party packages on $serial...\n');
  final pkgs = await listAndroidPackages(serial);
  if (pkgs.isEmpty) {
    stderr.writeln('No third-party packages found on $serial.');
    return null;
  }
  final pkg = _pickFromList('Pick a package', pkgs);
  if (pkg == null) return null;
  return AndroidBackend(serial: serial, pkg: pkg, model: model);
}

Future<Backend?> _pickIosApp(String deviceId, String deviceName) async {
  stdout.write('Listing apps on $deviceName (may take a few seconds)...\n');
  final List<IosApp> apps;
  try {
    apps = await listIosApps(deviceId);
  } catch (e) {
    stderr.writeln('Failed to list apps: $e');
    return null;
  }
  if (apps.isEmpty) {
    stderr.writeln('No developer apps found on $deviceName.');
    return null;
  }
  final labels = apps.map((a) => a.toString()).toList();
  final idx = _pickIndexFromList('Pick an app', labels);
  if (idx == null) return null;
  return IosBackend(
    deviceId: deviceId,
    bundleId: apps[idx].bundleId,
    deviceName: deviceName,
    onProgress: (msg) => stdout.writeln(msg),
  );
}

String? _pickFromList(String prompt, List<String> options) {
  final idx = _pickIndexFromList(prompt, options);
  return idx == null ? null : options[idx];
}

int? _pickIndexFromList(String prompt, List<String> options) {
  if (options.length == 1) {
    stdout.writeln('$prompt: ${options[0]}');
    return 0;
  }
  stdout.writeln('');
  for (var i = 0; i < options.length; i++) {
    stdout.writeln(' [$i] ${options[i]}');
  }
  final idx = _promptIndex(prompt, options.length);
  return idx < 0 ? null : idx;
}

int _promptIndex(String prompt, int count) {
  while (true) {
    stdout.write('$prompt [0-${count - 1}]: ');
    final line = stdin.readLineSync();
    if (line == null) return -1;
    final n = int.tryParse(line.trim());
    if (n != null && n >= 0 && n < count) return n;
    stdout.writeln(' invalid');
  }
}

// ---------------------------------------------------------------------------
// Android: drop into real adb shell (CLI-only - uses inheritStdio)
// ---------------------------------------------------------------------------

Future<int> dropIntoAdbShell(String serial, String pkg) async {
  final adb = resolveAdbPath();
  if (adb == null) {
    stderr.writeln('adb not found');
    return 1;
  }
  final debuggable = await isAndroidPackageDebuggable(serial, pkg);
  final args = ['-s', serial, 'shell', '-t'];
  if (debuggable) {
    args.addAll(['run-as', pkg]);
    stdout.writeln(
      'Dropping into adb shell inside the app data dir (/data/data/$pkg/).',
    );
    stdout.writeln(
      'You have the real device tools - ls, cat, grep, find, du, sh, sqlite3 (if present), etc.',
    );
    stdout.writeln('Examples:');
    stdout.writeln(' ls -la');
    stdout.writeln(' ls -lhS <dir> # sort entries by size');
    stdout.writeln(' find . -name "*.db" # locate files by pattern');
    stdout.writeln(' rm <path> # delete a file');
    stdout.writeln('To pull a file to your Mac, open another terminal:');
    stdout.writeln(
      ' $adb -s $serial exec-out run-as $pkg cat <remote-path> > <local-file>',
    );
    stdout.writeln('Ctrl-D or `exit` to return.');
  } else {
    stdout.writeln('NOTE: $pkg is not debuggable - run-as is refused.');
    stdout.writeln('To access /data/data/$pkg/ you need a debug install:');
    stdout.writeln(' flutter run --flavor dev -t lib/main_dev.dart');
    stdout.writeln('');
    stdout.writeln(
      'Opening a plain device shell instead (no run-as). You can still reach',
    );
    stdout.writeln(
      '/sdcard, /data/local/tmp, /system, and apps with world-readable files.',
    );
  }
  stdout.writeln('');
  final proc =
      await Process.start(adb, args, mode: ProcessStartMode.inheritStdio);
  return proc.exitCode;
}

// ---------------------------------------------------------------------------
// iOS REPL (CLI-only - devicectl has no shell, so we wrap its file ops)
// ---------------------------------------------------------------------------

class IosRepl {
  IosRepl(this.backend);

  final IosBackend backend;
  String cwd = '';

  Future<void> run() async {
    stdout.writeln(
      '\nConnected: ${backend.deviceLabel} app: ${backend.appLabel}',
    );
    stdout.writeln(
      'iOS has no device shell via devicectl - using file-API REPL.',
    );
    stdout.writeln(
      'Paths are relative to the app data container root. `help` for commands.',
    );
    stdout.writeln('');
    while (true) {
      stdout.write('${cwd.isEmpty ? '/' : '/$cwd'}> ');
      final raw = stdin.readLineSync();
      if (raw == null) {
        stdout.writeln('');
        return;
      }
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parts = _splitArgs(line);
      final cmd = parts[0];
      final args = parts.sublist(1);
      try {
        switch (cmd) {
          case 'help' || 'h' || '?':
            _printHelp();
          case 'quit' || 'exit' || 'q':
            return;
          case 'pwd':
            stdout.writeln(cwd.isEmpty ? '/' : '/$cwd');
          case 'ls':
            await _ls(args);
          case 'cd':
            await _cd(args);
          case 'rm':
            await _rm(args);
          case 'clear':
            await _clear(args);
          case 'pull':
            await _pull(args);
          default:
            stdout.writeln('unknown command: $cmd (try `help`)');
        }
      } catch (e) {
        stderr.writeln('error: $e');
      }
    }
  }

  Future<void> _ls(List<String> args) async {
    final target = args.isEmpty ? cwd : _resolve(args.first);
    final entries = await backend.ls(target);
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (entries.isEmpty) {
      stdout.writeln('(empty)');
      return;
    }
    for (final e in entries) {
      final size = e.isDir ? '-' : _formatSize(e.sizeBytes);
      final name = e.isDir ? '${e.name}/' : e.name;
      stdout.writeln(' ${size.padLeft(10)} $name');
    }
  }

  Future<void> _cd(List<String> args) async {
    if (args.isEmpty) {
      cwd = '';
      return;
    }
    final next = _resolve(args.first);
    if (next.isNotEmpty) await backend.ls(next);
    cwd = next;
  }

  Future<void> _rm(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('usage: rm <path>');
      return;
    }
    final target = _resolve(args.first);
    if (target.isEmpty) {
      stdout.writeln('refuse to rm container root');
      return;
    }
    if (!_confirm('Delete $target ?')) return;
    await backend.rm(target);
    stdout.writeln('deleted: $target');
  }

  Future<void> _clear(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('usage: clear <path> (refuse to wipe container root)');
      return;
    }
    final target = _resolve(args.first);
    if (target.isEmpty) {
      stdout.writeln('refuse to wipe container root - specify a subpath');
      return;
    }
    if (!_confirm('Wipe ALL contents of $target ?')) return;
    await backend.clearDir(target);
    stdout.writeln('cleared: $target');
  }

  Future<void> _pull(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('usage: pull <remote-path> [local-path]');
      return;
    }
    final remote = _resolve(args[0]);
    if (remote.isEmpty) {
      stdout.writeln('refuse to pull container root; use a path');
      return;
    }
    final local = args.length >= 2 ? args[1] : remote.split('/').last;
    final localFile = File(local);
    if (await localFile.exists()) {
      if (!_confirm('Overwrite local $local ?')) return;
    } else {
      await localFile.parent.create(recursive: true);
    }
    await backend.pull(remote, local);
    stdout.writeln('pulled: $remote -> $local');
  }

  String _resolve(String arg) {
    if (arg == '/' || arg == '~') return '';
    final base = arg.startsWith('/')
        ? <String>[]
        : cwd.split('/').where((s) => s.isNotEmpty).toList();
    for (final seg in arg.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (base.isNotEmpty) base.removeLast();
      } else {
        base.add(seg);
      }
    }
    return base.join('/');
  }

  bool _confirm(String prompt) {
    stdout.write('$prompt [y/N] ');
    final line = stdin.readLineSync();
    if (line == null) return false;
    final t = line.trim().toLowerCase();
    return t == 'y' || t == 'yes';
  }

  void _printHelp() {
    stdout.writeln('''
Commands (iOS file-API REPL):
 ls [path] list directory (default: cwd)
 cd <path> change directory (.. supported; no arg returns to root)
 pwd print current directory
 rm <path> delete a single file (slow on iOS - see notes)
 clear <path> wipe ALL contents of <path> (path required; root refused)
 pull <remote> [local] download a file to the host
 help show this message
 quit exit

Notes:
 - Paths are relative to the app data container root.
 - iOS single-file `rm` downloads the parent dir, removes the file, and
 re-uploads with --remove-existing-content. Slow on big directories.
 Prefer `clear <dir>` for bulk wipes.

Typical iOS Flutter layout:
 Documents/ Library/ tmp/ SystemData/
 Flutter app docs live under Documents/
''');
  }
}

String _formatSize(int? bytes) {
  if (bytes == null) return '?';
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}G';
}

List<String> _splitArgs(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (!inSingle && !inDouble && (c == ' ' || c == '\t')) {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
      continue;
    }
    if (!inDouble && c == "'") {
      inSingle = !inSingle;
      continue;
    }
    if (!inSingle && c == '"') {
      inDouble = !inDouble;
      continue;
    }
    if (!inSingle && c == r'\' && i + 1 < line.length) {
      buf.write(line[++i]);
      continue;
    }
    buf.write(c);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

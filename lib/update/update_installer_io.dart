import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'update_source.dart';

/// Native builds have no page to reload.
Future<void> reloadPage() => throw UnsupportedError('reloadPage is web-only.');

/// Downloads [release], verifies it, and starts a detached helper that swaps
/// it in for the running app and relaunches it as soon as this process exits.
/// The caller quits the app right after this returns.
///
/// Nothing on disk changes until the app has quit: the helper moves the old
/// bundle aside, copies the new one in, and puts the old one back if the copy
/// fails. Throws [UpdateInstallException] when an in-place install is
/// impossible (not writable, translocated, bad download).
Future<void> installMacosUpdate(MacosRelease release, void Function(String stage) onStage) async {
  final appBundle = _runningAppBundle();
  _checkCanReplace(appBundle);

  final work = await Directory.systemTemp.createTemp('dbscope-update-');
  final zip = File('${work.path}/${ReleaseSource.macosZipAsset}');

  onStage('Downloading dbscope ${release.version}…');
  final checksums = await _get(release.checksumsUrl);
  await _download(release.zipUrl, zip);

  onStage('Verifying…');
  final expected = checksumFor(checksums, ReleaseSource.macosZipAsset);
  final actual = (await sha256.bind(zip.openRead()).first).toString();
  if (actual != expected) {
    throw const UpdateInstallException('The download is corrupt (checksum mismatch).');
  }

  final unpacked = Directory('${work.path}/unpacked');
  await _run('ditto', ['-x', '-k', zip.path, unpacked.path]);
  final newBundle = Directory('${unpacked.path}/dbscope.app');
  if (!newBundle.existsSync()) {
    throw const UpdateInstallException('The download does not contain dbscope.app.');
  }
  final runningId = await _bundleId(appBundle);
  final newId = await _bundleId(newBundle);
  if (runningId != newId) {
    throw UpdateInstallException('The download is a different app ($newId).');
  }

  onStage('Installing… dbscope will restart.');
  final script = File('${work.path}/swap.sh');
  await script.writeAsString(_swapScript);
  await Process.start(
    '/bin/bash',
    [script.path, '$pid', appBundle.path, newBundle.path, work.path],
    mode: ProcessStartMode.detached,
  );
}

/// `/Applications/dbscope.app` from `.../dbscope.app/Contents/MacOS/dbscope`.
Directory _runningAppBundle() {
  final bundle = File(Platform.resolvedExecutable).parent.parent.parent;
  if (!bundle.path.endsWith('.app')) {
    throw UpdateInstallException('dbscope is not running from an app bundle (${bundle.path}).');
  }
  return bundle;
}

void _checkCanReplace(Directory appBundle) {
  // Gatekeeper runs a quarantined app from a read-only random path until the
  // user moves it; replacing that copy would change nothing.
  if (appBundle.path.contains('/AppTranslocation/')) {
    throw const UpdateInstallException(
      'Move dbscope to the Applications folder first, then update.',
    );
  }
  final probe = File('${appBundle.parent.path}/.dbscope-update-probe-$pid');
  try {
    probe.writeAsStringSync('');
    probe.deleteSync();
  } on FileSystemException {
    throw UpdateInstallException("dbscope can't write to ${appBundle.parent.path}.");
  }
}

Future<String> _get(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw UpdateInstallException('Download failed (HTTP ${response.statusCode}).');
  }
  return response.body;
}

Future<void> _download(Uri url, File to) async {
  final client = http.Client();
  try {
    final response = await client.send(http.Request('GET', url));
    if (response.statusCode != 200) {
      throw UpdateInstallException('Download failed (HTTP ${response.statusCode}).');
    }
    await response.stream.pipe(to.openWrite());
  } finally {
    client.close();
  }
}

Future<String> _bundleId(Directory bundle) async {
  final result = await _run('/usr/libexec/PlistBuddy', [
    '-c',
    'Print CFBundleIdentifier',
    '${bundle.path}/Contents/Info.plist',
  ]);
  return result.trim();
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw UpdateInstallException('$executable failed: ${result.stderr}'.trim());
  }
  return result.stdout as String;
}

/// Runs detached after dbscope quits: `swap.sh <pid> <app> <new app> <work dir>`.
/// Logs to ~/Library/Logs/dbscope-update.log.
const _swapScript = r'''
# dbscope self-update (run as `bash swap.sh ...`): waits for the running app to quit, swaps the bundle, relaunches.
set -u
pid="$1"; app="$2"; new="$3"; work="$4"
mkdir -p "$HOME/Library/Logs"
exec >>"$HOME/Library/Logs/dbscope-update.log" 2>&1
echo "$(date) updating $app from $new"

# Wait up to 60 s for dbscope to quit; give up (old app untouched) if it doesn't.
for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$pid" 2>/dev/null; then echo "dbscope did not quit; update abandoned"; exit 1; fi

backup="$app.previous"
rm -rf "$backup"
mv "$app" "$backup" || { echo "could not move the old app aside"; exit 1; }
if ditto "$new" "$app"; then
  rm -rf "$backup"
  echo "installed"
else
  echo "copy failed; restoring the previous version"
  rm -rf "$app"
  mv "$backup" "$app"
fi
xattr -dr com.apple.quarantine "$app" 2>/dev/null
open "$app"
rm -rf "$work"
''';

# app_data_explorer

General-purpose CLI and Dart library for exploring and manipulating any app's
sandboxed data on a plugged-in Android or iOS device.

- **Android** uses `adb shell` (with `run-as <pkg>` for debuggable builds).
- **iOS**     uses `xcrun devicectl` (built into Xcode).

The library exposes a thin `Backend` abstraction so the same code drives both
the CLI in `bin/` and the macOS UI in `../session_viewer/`. A future Flutter
session viewer or any other Dart tool can import the same library.

## Layout

```
app_data_explorer/
  pubspec.yaml
  lib/
    app_data_explorer.dart   # public library API
  bin/
    app_data_explorer.dart   # interactive CLI (uses the library)
```

## Requirements

- **Dart SDK** 3.0+
- **Android side**:
  - `adb` somewhere reachable. The library searches `$PATH` first, then
    `$ANDROID_HOME/platform-tools/adb`, `$ANDROID_SDK_ROOT/platform-tools/adb`,
    `~/Library/Android/sdk/platform-tools/adb`, `~/Android/Sdk/platform-tools/adb`,
    `/usr/local/bin/adb`, `/opt/homebrew/bin/adb`.
  - For access to `/data/data/<pkg>/`, the target APK must be **debuggable**.
    A release/App-Store APK will give `run-as: package not debuggable`.
    Install a debug build with e.g. `fvm flutter run --flavor dev -t lib/main_dev.dart`.
- **iOS side**:
  - Xcode installed (provides `xcrun devicectl`).
  - Device paired and developer mode enabled.
  - For most apps `devicectl` can reach the app data container; if a call
    returns an entitlement error, install via Xcode (development cert).

## CLI

Run from this directory:

```
dart run bin/app_data_explorer.dart
```

What it does:

1. Scans for connected Android devices (`adb devices`) and iOS devices
   (`xcrun devicectl list devices`).
2. Prompts you to pick one device, then an installed app.
3. **Android**: drops you into a real `adb shell` (wrapped in `run-as <pkg>`
   when debuggable). You use the device's own `ls`, `cat`, `grep`, `find`,
   `du`, `sh`, etc. - nothing reimplemented. To pull a file to your Mac from
   another terminal:
   ```
   adb -s <serial> exec-out run-as <pkg> cat <remote-path> > <local-file>
   ```
4. **iOS**: drops you into a small file-API REPL (devicectl has no shell):
   ```
   ls [path]            list directory (default: cwd)
   cd <path>            change directory ('..' supported)
   pwd                  print current directory
   rm <path>            delete a single file
   clear <path>         wipe ALL contents of <path>  (path required)
   pull <remote> [local] download a file to the host
   help / quit
   ```
   Single-file `rm` on iOS is emulated by downloading the parent directory,
   removing the file locally, and re-uploading with
   `--remove-existing-content`. Slow on large dirs - prefer `clear <dir>`
   for bulk wipes. `clear` refuses to operate on the container root.

## Library

Add a path dependency in your `pubspec.yaml`:

```yaml
dependencies:
  app_data_explorer:
    path: ../app_data_explorer
```

Then:

```dart
import 'package:app_data_explorer/app_data_explorer.dart';

Future<void> main() async {
  // Discover devices.
  final android = await detectAndroidDevices();  // returns devices + hint
  final ios = await detectIosDevices();          // returns list

  // Pick an Android device and list its third-party apps.
  if (android.devices.isNotEmpty) {
    final dev = android.devices.first;
    final pkgs = await listAndroidPackages(dev.serial);
    final debuggable = await isAndroidPackageDebuggable(dev.serial, pkgs.first);

    final backend = AndroidBackend(
      serial: dev.serial,
      pkg: pkgs.first,
      model: dev.model,
    );

    final entries = await backend.ls('app_flutter');
    for (final e in entries) {
      print('${e.isDir ? "D" : "F"}  ${e.sizeBytes ?? "?"}  ${e.name}');
    }
  }

  // iOS equivalent.
  if (ios.isNotEmpty) {
    final apps = await listIosApps(ios.first.identifier);
    final backend = IosBackend(
      deviceId: ios.first.identifier,
      bundleId: apps.first.bundleId,
      deviceName: ios.first.name,
      onProgress: print, // hooks long iOS roundtrips (e.g. rm)
    );
    final entries = await backend.ls('Documents');
    print(entries.map((e) => e.name).toList());
  }
}
```

### Public API summary

| Symbol | Purpose |
|--------|---------|
| `Backend` (abstract) | Common interface: `ls`, `rm`, `clearDir`, `pull` |
| `Entry` | `{ name, isDir, sizeBytes }` |
| `AndroidBackend(serial, pkg, model)` | `adb shell run-as`-backed ops |
| `IosBackend(deviceId, bundleId, deviceName, onProgress?)` | `xcrun devicectl`-backed ops |
| `detectAndroidDevices()` | Returns `AndroidDetectionResult { devices, hint? }` |
| `detectIosDevices()` | Returns `List<IosDeviceInfo>` |
| `listAndroidPackages(serial, {includeSystem})` | `pm list packages` |
| `listIosApps(deviceId, {includeSystem})` | `devicectl device info apps` |
| `isAndroidPackageDebuggable(serial, pkg)` | Probes `run-as <pkg> true` |
| `resolveAdbPath()` | Finds `adb` on PATH or in standard SDK dirs |

Paths passed to `ls`/`rm`/`clearDir`/`pull` are relative to the app data
container root:

- **Android (under `run-as`)**: `/data/data/<pkg>/` is the root. Typical
  Flutter subdirs: `app_flutter/`, `cache/`, `databases/`, `shared_prefs/`,
  `files/`, `code_cache/`, `no_backup/`.
- **iOS (`appDataContainer` domain)**: container root. Typical Flutter subdirs:
  `Documents/`, `Library/`, `Library/Caches/`, `tmp/`, `SystemData/`.

## Platform limitations

- **Android release APKs are inaccessible.** `run-as` is refused for any APK
  built without `android:debuggable=true`. There is no workaround short of
  rooting the device or installing a debug build.
- **iOS single-file `rm` is slow** (download parent + reupload). For wiping
  many files, use `clearDir`.
- **iOS tunnel flakiness**: devicectl sometimes returns
  "device disconnected immediately after connecting" if the device went to
  sleep. The library retries each operation once on these transient errors.
- **No symlink resolution**: symlinks are displayed with a trailing `@` and
  their targets are not followed.

## See also

- `../session_viewer/` - Flutter macOS UI built on top of this library,
  focused on session bins, playbacks, sqlite DB, and logs.

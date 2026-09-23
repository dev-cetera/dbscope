// Device + app discovery helpers, layered on top of app_data_explorer.
//
// The plugin's profile dialog uses these to populate the three dropdowns:
// device, app, then on-device SQLite file. Backend (AndroidBackend /
// IosBackend) instances are short-lived: probe-during-discovery and
// fresh-at-open-time. They carry no socket state so reconstructing them
// at open time is fine.

import 'package:app_data_explorer/app_data_explorer.dart';

/// Lightweight summary of a connected device, regardless of platform.
class DiscoveredDevice {
  final String kind; // 'android' | 'ios'
  final String id;
  final String label;
  final String? model;
  DiscoveredDevice({
    required this.kind,
    required this.id,
    required this.label,
    this.model,
  });
}

/// Lightweight summary of an app installed on a device. For Android this
/// is the package name, for iOS the bundle identifier. [debuggable] is
/// always true on iOS (devicectl reaches both Xcode-installed and
/// App-Store apps); on Android it reflects `run-as` reachability.
class DiscoveredApp {
  final String id;
  final String? displayName;
  final bool debuggable;
  DiscoveredApp({
    required this.id,
    this.displayName,
    required this.debuggable,
  });
}

/// One on-device file that looks like a SQLite database.
class DiscoveredDbFile {
  final String relativePath;
  final int? sizeBytes;
  DiscoveredDbFile({required this.relativePath, this.sizeBytes});
}

/// Errors / surfacing hints from device discovery. Non-fatal; the dialog
/// shows these inline so the user can act on them.
class DeviceDiscovery {
  final List<DiscoveredDevice> devices;
  final String? hint;
  DeviceDiscovery({required this.devices, this.hint});
}

Future<DeviceDiscovery> discoverDevices() async {
  final out = <DiscoveredDevice>[];
  String? hint;
  final android = await detectAndroidDevices();
  for (final d in android.devices) {
    out.add(
      DiscoveredDevice(
        kind: 'android',
        id: d.serial,
        label: d.model == null ? d.serial : '${d.model} (${d.serial})',
        model: d.model,
      ),
    );
  }
  if (android.hint != null) hint = android.hint;
  final ios = await detectIosDevices();
  for (final d in ios) {
    out.add(
      DiscoveredDevice(
        kind: 'ios',
        id: d.identifier,
        label: d.name,
      ),
    );
  }
  return DeviceDiscovery(devices: out, hint: hint);
}

/// Lists apps on [device] whose data container has content dbscope can
/// reach. On Android that means debuggable + non-empty data dir; on iOS
/// that means devicectl can list the container and it's non-empty.
Future<List<DiscoveredApp>> discoverApps(DiscoveredDevice device) async {
  if (device.kind == 'android') {
    final pkgs = await listAndroidPackages(device.id);
    final out = <DiscoveredApp>[];
    // Probe in parallel so a phone with many third-party apps doesn't
    // make the dialog feel frozen.
    final probes = <Future<void>>[];
    for (final pkg in pkgs) {
      probes.add(() async {
        final ok = await androidAppHasData(device.id, pkg);
        if (ok) out.add(DiscoveredApp(id: pkg, debuggable: true));
      }());
    }
    await Future.wait(probes);
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }
  if (device.kind == 'ios') {
    final apps = await listIosApps(device.id);
    final out = <DiscoveredApp>[];
    final probes = <Future<void>>[];
    for (final a in apps) {
      probes.add(() async {
        final ok = await iosAppHasData(device.id, a.bundleId);
        if (ok) {
          out.add(
            DiscoveredApp(
              id: a.bundleId,
              displayName: a.name,
              debuggable: true,
            ),
          );
        }
      }());
    }
    await Future.wait(probes);
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }
  return const [];
}

/// Walks the app data container and returns every file that looks like a
/// SQLite database. Recognised extensions: `.db`, `.sqlite`, `.sqlite3`,
/// `.db3`. WAL/SHM sidecars are NOT included — they're paired with their
/// `.db` at open time.
Future<List<DiscoveredDbFile>> discoverDbFiles(Backend backend) async {
  final entries = await backend.lsRecursive('');
  const exts = ['.db', '.sqlite', '.sqlite3', '.db3'];
  final out = <DiscoveredDbFile>[];
  for (final e in entries) {
    if (e.isDir) continue;
    final lower = e.name.toLowerCase();
    if (lower.endsWith('-wal') ||
        lower.endsWith('-shm') ||
        lower.endsWith('-journal')) {
      continue;
    }
    if (!exts.any(lower.endsWith)) continue;
    out.add(DiscoveredDbFile(relativePath: e.name, sizeBytes: e.sizeBytes));
  }
  out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return out;
}

/// Builds the appropriate Backend for [device] + [appId]. Cheap; the
/// backend is just a wrapper around the device id and app id.
Backend buildBackend(DiscoveredDevice device, String appId) {
  if (device.kind == 'android') {
    return AndroidBackend(serial: device.id, pkg: appId, model: device.model);
  }
  if (device.kind == 'ios') {
    return IosBackend(
      deviceId: device.id,
      bundleId: appId,
      deviceName: device.label,
    );
  }
  throw StateError('unknown device kind: ${device.kind}');
}

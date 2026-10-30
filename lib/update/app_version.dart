import 'package:flutter/foundation.dart' show immutable;

/// The running build's version, stamped at build time by CI with
/// `--dart-define=APP_VERSION=...` (`.github/workflows/release.yml` for
/// macOS, `web.yml` for web). Empty on a local `flutter run`: such a build
/// has nothing to compare against, so update checks stay off.
// A build-time stamp is the point: the version must be baked into the binary
// that is running, not read from anything that could change after the build.
// ignore: do_not_use_environment
const kRunningVersionStamp = String.fromEnvironment('APP_VERSION');

/// A `major.minor.patch` version with an optional `+build` number, as written
/// by CI (`0.2.0`, `0.2.0+57`) and by GitHub release tags (`v0.2.0`).
///
/// Ordering compares major, minor, patch, then build. A missing build counts
/// as 0, so `0.2.0+3` is newer than `0.2.0`, which is what the web deploy
/// relies on: every push to main keeps the pubspec version and bumps only
/// the build number.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build = 0});

  final int major;
  final int minor;
  final int patch;
  final int build;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:[-+](\d+))?$');

  /// Parses `0.2.0`, `v0.2.0` or `0.2.0+57`. Returns null for anything else
  /// (an empty stamp, a pre-release tag like `v0.2.0-beta`), so the caller
  /// decides what an unparseable version means.
  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      build: int.parse(match.group(4) ?? '0'),
    );
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  /// `0.2.0`, or `0.2.0+57` when there is a build number.
  @override
  String toString() => build == 0 ? '$major.$minor.$patch' : '$major.$minor.$patch+$build';
}

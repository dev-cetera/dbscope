import 'app_version.dart';

/// Where releases are published. The asset names are a contract with
/// `.github/workflows/release.yml`, which uploads them without a version in
/// the name (the README and landing page link to them too).
abstract final class ReleaseSource {
  static const owner = 'dev-cetera';
  static const repo = 'dbscope';
  static const macosZipAsset = 'dbscope-macos.zip';
  static const checksumsAsset = 'SHA256SUMS.txt';

  static final Uri latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases/latest',
  );
  static final Uri releasesPage = Uri.parse('https://github.com/$owner/$repo/releases/latest');
}

/// The keys of the `version.json` Flutter's web build writes next to the
/// bundle (`version` + `build_number`, from `--build-name` / `--build-number`).
abstract final class VersionJsonKeys {
  static const version = 'version';
  static const buildNumber = 'build_number';
}

/// The fields of GitHub's "get the latest release" response that are read.
abstract final class GithubReleaseKeys {
  static const tagName = 'tag_name';
  static const htmlUrl = 'html_url';
  static const assets = 'assets';
  static const assetName = 'name';
  static const assetDownloadUrl = 'browser_download_url';
}

/// A published macOS release with everything the installer needs.
class MacosRelease {
  const MacosRelease({
    required this.version,
    required this.zipUrl,
    required this.checksumsUrl,
    required this.pageUrl,
  });

  final AppVersion version;
  final Uri zipUrl;
  final Uri checksumsUrl;
  final Uri pageUrl;
}

/// Why an update couldn't be installed in place. [message] is shown to the
/// user as-is, next to a link to the release page for a manual install.
class UpdateInstallException implements Exception {
  const UpdateInstallException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads the deployed build's version out of the web `version.json`.
/// Throws [FormatException] when the file isn't the shape Flutter writes.
AppVersion parseVersionJson(Map<String, Object?> json) {
  final version = json[VersionJsonKeys.version];
  final build = json[VersionJsonKeys.buildNumber];
  if (version is! String) {
    throw const FormatException('version.json has no "version" string');
  }
  final joined = (build is String && build.isNotEmpty) ? '$version+$build' : version;
  return AppVersion.tryParse(joined) ??
      (throw FormatException('version.json has an unparseable version "$joined"'));
}

/// Reads a GitHub "latest release" response. Throws [FormatException] when
/// the tag isn't a plain version or the release lacks the macOS zip or the
/// checksums file: a release the installer can't verify is not offered.
MacosRelease parseGithubRelease(Map<String, Object?> json) {
  final tag = json[GithubReleaseKeys.tagName];
  final page = json[GithubReleaseKeys.htmlUrl];
  final assets = json[GithubReleaseKeys.assets];
  if (tag is! String || page is! String || assets is! List<Object?>) {
    throw const FormatException('GitHub release is missing tag_name, html_url or assets');
  }
  final version = AppVersion.tryParse(tag) ??
      (throw FormatException('GitHub release tag "$tag" is not a version'));

  Uri assetUrl(String name) {
    for (final asset in assets) {
      if (asset is Map<String, Object?> && asset[GithubReleaseKeys.assetName] == name) {
        final url = asset[GithubReleaseKeys.assetDownloadUrl];
        if (url is String) return Uri.parse(url);
      }
    }
    throw FormatException('GitHub release $tag has no $name asset');
  }

  return MacosRelease(
    version: version,
    zipUrl: assetUrl(ReleaseSource.macosZipAsset),
    checksumsUrl: assetUrl(ReleaseSource.checksumsAsset),
    pageUrl: Uri.parse(page),
  );
}

/// Finds the SHA-256 of [fileName] in a `shasum -a 256` listing
/// (`<hex>  <name>` per line). Throws [FormatException] when it's absent.
String checksumFor(String checksums, String fileName) {
  for (final line in checksums.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 2 && parts[1].replaceFirst('*', '') == fileName) {
      return parts[0].toLowerCase();
    }
  }
  throw FormatException('No checksum for $fileName');
}

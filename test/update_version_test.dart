// Contract: the update check offers a build only when it is strictly newer
// than the running one, and only a macOS release the installer can verify.
//
// - AppVersion orders major, minor, patch, then build; a missing build is 0,
//   so each web deploy (same pubspec version, higher build number) is newer.
// - Anything that isn't a plain version (empty stamp, pre-release tag) does
//   not parse, so it is never offered.
// - version.json joins Flutter's `version` + `build_number`.
// - A GitHub release without the macOS zip or SHA256SUMS.txt is rejected:
//   the installer must be able to verify what it downloads.
// - checksumFor reads `shasum -a 256` output and fails loudly when absent.

import 'package:dbscope/update/app_version.dart';
import 'package:dbscope/update/update_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppVersion', () {
    test('parses plain, v-prefixed and build-numbered versions', () {
      expect(AppVersion.tryParse('0.2.0'), const AppVersion(0, 2, 0));
      expect(AppVersion.tryParse('v0.2.0'), const AppVersion(0, 2, 0));
      expect(AppVersion.tryParse('0.2.0+57'), const AppVersion(0, 2, 0, build: 57));
    });

    test('rejects empty stamps and pre-release tags', () {
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('v0.2.0-beta'), isNull);
      expect(AppVersion.tryParse('dev'), isNull);
    });

    test('orders by major, minor, patch, then build', () {
      const v = AppVersion.tryParse;
      expect(v('0.2.0')!.isNewerThan(v('0.1.9')!), isTrue);
      expect(v('1.0.0')!.isNewerThan(v('0.99.99')!), isTrue);
      expect(v('0.1.10')!.isNewerThan(v('0.1.9')!), isTrue);
      expect(v('0.1.0+58')!.isNewerThan(v('0.1.0+57')!), isTrue);
      expect(v('0.1.0+1')!.isNewerThan(v('0.1.0')!), isTrue);
    });

    test('an equal or older build is never newer', () {
      const v = AppVersion.tryParse;
      expect(v('0.2.0')!.isNewerThan(v('v0.2.0')!), isFalse);
      expect(v('0.1.0+57')!.isNewerThan(v('0.1.0+58')!), isFalse);
    });

    test('prints the build number only when there is one', () {
      expect('${const AppVersion(0, 2, 0)}', '0.2.0');
      expect('${const AppVersion(0, 2, 0, build: 7)}', '0.2.0+7');
    });
  });

  group('parseVersionJson', () {
    test('joins version and build_number', () {
      final json = {'app_name': 'dbscope', 'version': '0.1.0', 'build_number': '58'};
      expect(parseVersionJson(json), const AppVersion(0, 1, 0, build: 58));
    });

    test('throws on a file without a version', () {
      expect(() => parseVersionJson({'build_number': '1'}), throwsFormatException);
    });
  });

  group('parseGithubRelease', () {
    Map<String, Object?> release({List<String> assets = const ['dbscope-macos.zip', 'SHA256SUMS.txt']}) => {
      'tag_name': 'v0.2.0',
      'html_url': 'https://github.com/dev-cetera/dbscope/releases/tag/v0.2.0',
      'assets': [
        for (final name in assets)
          {'name': name, 'browser_download_url': 'https://example.test/$name'},
      ],
    };

    test('reads the version and the zip and checksum URLs', () {
      final parsed = parseGithubRelease(release());
      expect(parsed.version, const AppVersion(0, 2, 0));
      expect(parsed.zipUrl.toString(), 'https://example.test/dbscope-macos.zip');
      expect(parsed.checksumsUrl.toString(), 'https://example.test/SHA256SUMS.txt');
    });

    test('rejects a release the installer could not verify', () {
      expect(() => parseGithubRelease(release(assets: ['dbscope-macos.zip'])), throwsFormatException);
      expect(() => parseGithubRelease(release(assets: ['SHA256SUMS.txt'])), throwsFormatException);
    });

    test('rejects a non-version tag', () {
      expect(() => parseGithubRelease({...release(), 'tag_name': 'nightly'}), throwsFormatException);
    });
  });

  group('checksumFor', () {
    const sums = 'ABC123  dbscope-macos.dmg\ndef456  dbscope-macos.zip\n';

    test('finds the line for the file, lowercased', () {
      expect(checksumFor(sums, 'dbscope-macos.zip'), 'def456');
      expect(checksumFor(sums, 'dbscope-macos.dmg'), 'abc123');
    });

    test('throws when the file is not listed', () {
      expect(() => checksumFor(sums, 'other.zip'), throwsFormatException);
    });
  });
}

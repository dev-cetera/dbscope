// Contract: autoConnectProfileFromEnv reads DBSCOPE_AUTO_* variables.
// * No DBSCOPE_AUTO_HOST, no profile.
// * DBSCOPE_AUTO_READ_ONLY accepts true/1/yes/on and false/0/no/off in any
//   case. Anything else leaves it to the name heuristic, never to
//   read-write: `=1` on a production profile must not open it writable.

import 'package:dbscope/connection/cli_auto_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'DBSCOPE_AUTO_HOST': 'db.example.com',
    'DBSCOPE_AUTO_NAME': 'reporting',
    ...extra,
  };

  test('no host, no profile', () {
    expect(autoConnectProfileFromEnv(const {}), isNull);
  });

  test('READ_ONLY=1 and =TRUE open read-only', () {
    for (final value in ['1', 'TRUE', 'true', 'Yes', 'on']) {
      expect(autoConnectProfileFromEnv(env({'DBSCOPE_AUTO_READ_ONLY': value}))!.readOnly, isTrue, reason: value);
    }
  });

  test('READ_ONLY=0 and =false open read-write', () {
    for (final value in ['0', 'false', 'NO', 'off']) {
      expect(autoConnectProfileFromEnv(env({'DBSCOPE_AUTO_READ_ONLY': value}))!.readOnly, isFalse, reason: value);
    }
  });

  test('an unrecognised READ_ONLY value falls back to the name heuristic', () {
    final prod = autoConnectProfileFromEnv(env({'DBSCOPE_AUTO_NAME': 'prod', 'DBSCOPE_AUTO_READ_ONLY': 'y3s'}))!;
    expect(prod.readOnly, isTrue);
  });
}

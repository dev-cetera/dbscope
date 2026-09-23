// Pins the contract of the portable `.dbscopeconn` connection link:
// - encode()/decode() round-trips a profile *including its password*
// - the password is never present in cleartext in the file
// - a wrong passphrase fails with BadPassphraseException (not garbage)
// - a tampered ciphertext fails authentication
// - non-connection JSON is rejected as a FormatException
//
// These run on the VM without a database — the crypto is pure Dart.

import 'dart:convert';

import 'package:dbscope/connection/connection_link.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ConnectionProfile sampleProfile() => ConnectionProfile(
    id: 'fixed-id-123',
    kind: 'cloudsql',
    name: 'compledo prod',
    host: '127.0.0.1',
    port: 9480,
    database: 'compledo',
    username: 'app',
    password: 'super-secret-p@ss w0rd',
    sslMode: SslMode.disable,
    readOnly: true,
    extra: const {
      'instanceConnectionName':
          'compledo-prod:australia-southeast1:compledo-db-prod',
      'gcpProject': 'compledo-prod',
      'instanceName': 'compledo-db-prod',
      'localPort': 9480,
      'assignPublicIp': true,
    },
  );

  test('round-trips a profile and its password', () async {
    final profile = sampleProfile();
    final json = await ConnectionLink.encode(
      profile: profile,
      passphrase: 'open sesame',
    );
    final decoded = await ConnectionLink.decode(
      jsonText: json,
      passphrase: 'open sesame',
    );

    expect(decoded.password, profile.password);
    expect(decoded.id, profile.id);
    expect(decoded.kind, 'cloudsql');
    expect(decoded.database, 'compledo');
    expect(decoded.username, 'app');
    expect(decoded.readOnly, isTrue);
    expect(
      decoded.extra['instanceConnectionName'],
      'compledo-prod:australia-southeast1:compledo-db-prod',
    );
  });

  test('the password never appears in cleartext in the file', () async {
    final json = await ConnectionLink.encode(
      profile: sampleProfile(),
      passphrase: 'open sesame',
    );
    expect(json.contains('super-secret'), isFalse);
    // Sanity: it is a connection link with the expected shape.
    final map = jsonDecode(json) as Map<String, Object?>;
    expect(map['dbscopeConnection'], 1);
    expect((map['profile'] as Map).containsKey('password'), isFalse);
    expect((map['secret'] as Map)['alg'], 'aes-gcm-256');
  });

  test('wrong passphrase throws BadPassphraseException', () async {
    final json = await ConnectionLink.encode(
      profile: sampleProfile(),
      passphrase: 'correct horse',
    );
    expect(
      () => ConnectionLink.decode(jsonText: json, passphrase: 'wrong horse'),
      throwsA(isA<BadPassphraseException>()),
    );
  });

  test('tampered ciphertext fails authentication', () async {
    final json = await ConnectionLink.encode(
      profile: sampleProfile(),
      passphrase: 'pw',
    );
    final map = jsonDecode(json) as Map<String, Object?>;
    final secret = map['secret'] as Map<String, Object?>;
    // Flip the ciphertext to a different valid base64 blob of same length.
    final cipher = base64.decode(secret['ciphertext'] as String);
    cipher[0] = cipher[0] ^ 0xFF;
    secret['ciphertext'] = base64.encode(cipher);
    final tampered = jsonEncode(map);
    expect(
      () => ConnectionLink.decode(jsonText: tampered, passphrase: 'pw'),
      throwsA(isA<BadPassphraseException>()),
    );
  });

  test('non-connection JSON is rejected', () async {
    expect(
      () => ConnectionLink.decode(jsonText: '{"hello":1}', passphrase: 'x'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ConnectionLink.decode(jsonText: 'not json', passphrase: 'x'),
      throwsA(isA<FormatException>()),
    );
  });

  test('empty passphrase is rejected on encode', () async {
    expect(
      () => ConnectionLink.encode(profile: sampleProfile(), passphrase: ''),
      throwsA(isA<ArgumentError>()),
    );
  });
}

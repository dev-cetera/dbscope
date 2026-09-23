// Portable, self-contained connection file — "the connection link".
//
// A `.dbscopeconn` file carries a full [ConnectionProfile] *including the
// password* so that loading the file connects with no further setup. Unlike
// the on-disk project document (which keeps passwords in the OS keychain and
// omits them from JSON), the connection link is meant to be moved between
// machines — so the password travels inside it, encrypted with a passphrase.
//
// Format (JSON):
// {
// "dbscopeConnection": 1, // format version
// "profile": { ... }, // ConnectionProfile.toJson() (no pw)
// "secret": {
// "alg": "aes-gcm-256",
// "kdf": "pbkdf2-hmac-sha256",
// "iterations": 210000,
// "salt": "<base64>",
// "nonce": "<base64>",
// "ciphertext": "<base64>", // AES-GCM of the UTF-8 password
// "mac": "<base64>" // GCM auth tag
// }
// }
//
// The passphrase is never stored. A wrong passphrase (or a tampered file)
// fails the GCM tag check and surfaces as [BadPassphraseException].

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'profile.dart';

/// Thrown when the passphrase is wrong or the encrypted blob was tampered
/// with — GCM authentication failed, so we can't tell which.
class BadPassphraseException implements Exception {
  final String message;
  const BadPassphraseException([
    this.message = 'Wrong passphrase, or the connection file is corrupt.',
  ]);
  @override
  String toString() => message;
}

class ConnectionLink {
  ConnectionLink._();

  /// File extension (no dot) for connection links.
  static const String fileExtension = 'dbscopeconn';

  /// Current on-disk format version.
  static const int formatVersion = 1;

  static const int _defaultIterations = 210000;
  static const int _saltBytes = 16;

  static final Random _rng = Random.secure();

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  /// Encode [profile] (with its password) into the JSON text of a
  /// `.dbscopeconn` file, encrypting the password under [passphrase].
  static Future<String> encode({
    required ConnectionProfile profile,
    required String passphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError('A passphrase is required to export a connection.');
    }
    final salt = _randomBytes(_saltBytes);
    final key = await _deriveKey(passphrase, salt, _defaultIterations);
    final gcm = AesGcm.with256bits();
    final box = await gcm.encrypt(
      utf8.encode(profile.password),
      secretKey: key,
      nonce: gcm.newNonce(),
    );
    final doc = <String, Object?>{
      'dbscopeConnection': formatVersion,
      // toJson() deliberately omits the password — it lives in `secret`.
      'profile': profile.toJson(),
      'secret': {
        'alg': 'aes-gcm-256',
        'kdf': 'pbkdf2-hmac-sha256',
        'iterations': _defaultIterations,
        'salt': base64.encode(salt),
        'nonce': base64.encode(box.nonce),
        'ciphertext': base64.encode(box.cipherText),
        'mac': base64.encode(box.mac.bytes),
      },
    };
    return const JsonEncoder.withIndent(' ').convert(doc);
  }

  /// Decode a `.dbscopeconn` [jsonText] and decrypt its password with
  /// [passphrase], returning a ready-to-connect [ConnectionProfile].
  ///
  /// Throws [BadPassphraseException] on a wrong passphrase / tampered file
  /// and [FormatException] on anything that isn't a recognised connection
  /// link.
  static Future<ConnectionProfile> decode({
    required String jsonText,
    required String passphrase,
  }) async {
    Object? raw;
    try {
      raw = jsonDecode(jsonText);
    } catch (_) {
      throw const FormatException('Not a valid connection file.');
    }
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Not a valid connection file.');
    }
    final version = raw['dbscopeConnection'];
    if (version is! int) {
      throw const FormatException('Not a dbscope connection file.');
    }
    if (version > formatVersion) {
      throw FormatException(
        'This connection file (v$version) is newer than this app supports.',
      );
    }
    final profileJson = raw['profile'];
    final secret = raw['secret'];
    if (profileJson is! Map<String, Object?> ||
        secret is! Map<String, Object?>) {
      throw const FormatException('Connection file is missing fields.');
    }
    final iterations =
        (secret['iterations'] as num?)?.toInt() ?? _defaultIterations;
    final salt = _decodeB64(secret['salt']);
    final nonce = _decodeB64(secret['nonce']);
    final cipher = _decodeB64(secret['ciphertext']);
    final mac = _decodeB64(secret['mac']);
    if (salt == null || nonce == null || cipher == null || mac == null) {
      throw const FormatException('Connection file secret is malformed.');
    }
    final key = await _deriveKey(passphrase, salt, iterations);
    final gcm = AesGcm.with256bits();
    List<int> clear;
    try {
      clear = await gcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
    } on SecretBoxAuthenticationError {
      throw const BadPassphraseException();
    }
    final password = utf8.decode(clear);
    return ConnectionProfile.fromJson(profileJson, password);
  }

  static Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt,
    int iterations,
  ) {
    final pbkdf2 = Pbkdf2.hmacSha256(iterations: iterations, bits: 256);
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static List<int>? _decodeB64(Object? v) {
    if (v is! String) return null;
    try {
      return base64.decode(v);
    } catch (_) {
      return null;
    }
  }
}

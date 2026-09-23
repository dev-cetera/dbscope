import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  // macOS note: usesDataProtectionKeychain=false uses the legacy
  // file-based keychain, which does NOT require the
  // `keychain-access-groups` entitlement. Adding that entitlement breaks
  // launch on unsigned / Personal-Team debug builds because
  // $(AppIdentifierPrefix) resolves to nothing valid. The legacy
  // keychain still lives in the user's login keychain and persists
  // across restarts — secure enough for our purposes.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.unlocked,
      usesDataProtectionKeychain: false,
    ),
  );

  Future<String?> readPassword(String profileId) async {
    try {
      return await _storage.read(key: 'pw:$profileId');
    } catch (_) {
      return null;
    }
  }

  Future<void> writePassword(String profileId, String password) async {
    await _storage.write(key: 'pw:$profileId', value: password);
  }

  Future<void> deletePassword(String profileId) async {
    try {
      await _storage.delete(key: 'pw:$profileId');
    } catch (_) {}
  }

  // AI provider API keys live in the same keychain as connection
  // passwords, namespaced separately. The `ai_key_` prefix keeps them
  // from colliding with `pw:<profileId>` entries; the namespace is
  // small and global (one entry per provider, not per profile).

  Future<String?> readAiKey(String providerId) async {
    try {
      return await _storage.read(key: 'ai_key_$providerId');
    } catch (_) {
      return null;
    }
  }

  Future<void> writeAiKey(String providerId, String apiKey) async {
    await _storage.write(key: 'ai_key_$providerId', value: apiKey);
  }

  Future<void> deleteAiKey(String providerId) async {
    try {
      await _storage.delete(key: 'ai_key_$providerId');
    } catch (_) {}
  }
}

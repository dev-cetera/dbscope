import '../project/project_store.dart';
import 'profile.dart';
import 'secure_store.dart';

/// Thin facade over [ProjectStore]: profile JSON now lives inside the
/// project's `.dbscopeproj` document. Passwords still live in
/// SecureStore (the OS keychain), keyed by profile id.
class ProfileStore {
  ProfileStore._();
  static final instance = ProfileStore._();

  Future<List<ConnectionProfile>> load() async {
    final projectDocument = await ProjectStore.instance.load();
    final out = <ConnectionProfile>[];
    for (final entry in projectDocument.profiles) {
      final id = entry['id'] as String?;
      if (id == null) continue;
      final password = await SecureStore.instance.readPassword(id) ?? '';
      out.add(ConnectionProfile.fromJson(entry, password));
    }
    return out;
  }

  Future<void> save(List<ConnectionProfile> profiles) async {
    await ProjectStore.instance.setProfiles([
      for (final profile in profiles) profile.toJson(),
    ]);
    for (final profile in profiles) {
      if (profile.password.isNotEmpty) {
        await SecureStore.instance.writePassword(profile.id, profile.password);
      }
    }
  }

  Future<void> delete(ConnectionProfile profile) async {
    await SecureStore.instance.deletePassword(profile.id);
  }
}

import '../project/project_store.dart';
import 'profile.dart';
import 'secure_store.dart';

/// Thin facade over [ProjectStore]: profile JSON now lives inside the
/// project's `.dbscopeproj` document. Passwords still live in
/// SecureStore (the OS keychain), keyed by profile id.
class ProfileStore {
  ProfileStore._();
  static final ProfileStore instance = ProfileStore._();

  Future<List<ConnectionProfile>> load() async {
    final doc = await ProjectStore.instance.load();
    final out = <ConnectionProfile>[];
    for (final entry in doc.profiles) {
      final id = entry['id'] as String?;
      if (id == null) continue;
      final password = await SecureStore.instance.readPassword(id) ?? '';
      out.add(ConnectionProfile.fromJson(entry, password));
    }
    return out;
  }

  Future<void> save(List<ConnectionProfile> profiles) async {
    await ProjectStore.instance.setProfiles([
      for (final p in profiles) p.toJson(),
    ]);
    for (final p in profiles) {
      if (p.password.isNotEmpty) {
        await SecureStore.instance.writePassword(p.id, p.password);
      }
    }
  }

  Future<void> delete(ConnectionProfile p) async {
    await SecureStore.instance.deletePassword(p.id);
  }
}

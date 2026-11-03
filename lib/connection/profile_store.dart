import 'package:flutter/foundation.dart';

import '../project/project_store.dart';
import 'profile.dart';
import 'secure_store.dart';

/// Thin facade over [ProjectStore]: profile JSON now lives inside the
/// project's `.dbscopeproj` document. Passwords still live in
/// SecureStore (the OS keychain), keyed by profile id.
class ProfileStore {
  ProfileStore._();
  static final instance = ProfileStore._();

  /// Saved entries this build can't parse (hand-edited, or written by a
  /// newer build). They are left out of [load] and written back unchanged by
  /// [save], so one bad entry neither hides every other profile nor gets
  /// silently deleted by the next save.
  final List<Map<String, Object?>> _unreadable = [];

  Future<List<ConnectionProfile>> load() async {
    final projectDocument = await ProjectStore.instance.load();
    final out = <ConnectionProfile>[];
    _unreadable.clear();
    for (final entry in projectDocument.profiles) {
      final id = entry['id'];
      if (id is! String) {
        _unreadable.add(entry);
        continue;
      }
      try {
        final password = await SecureStore.instance.readPassword(id) ?? '';
        out.add(ConnectionProfile.fromJson(entry, password));
      } catch (e) {
        debugPrint('Skipped saved connection "$id": it could not be read ($e).');
        _unreadable.add(entry);
      }
    }
    return out;
  }

  Future<void> save(List<ConnectionProfile> profiles) async {
    final ids = {for (final profile in profiles) profile.id};
    await ProjectStore.instance.setProfiles([
      for (final profile in profiles) profile.toJson(),
      for (final entry in _unreadable)
        if (!ids.contains(entry['id'])) entry,
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

  /// Remove [profileId]'s stored password, keeping the profile.
  Future<void> forgetPassword(String profileId) async {
    await SecureStore.instance.deletePassword(profileId);
  }
}

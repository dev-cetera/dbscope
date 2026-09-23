// ProfileServiceClient — typed wrapper for profile.* methods.

import '../../connection/profile.dart';
import '../backend_client.dart';

class ProfileServiceClient {
  final BackendClient _client;
  ProfileServiceClient(this._client);

  Future<List<ConnectionProfile>> list() async {
    final result = await _client.request('profile.list');
    final list = result as List<Object?>? ?? const [];
    final out = <ConnectionProfile>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      // Profiles arrive without passwords by design; passwords are
      // fetched lazily via `password(id)` when actually opening a conn.
      out.add(ConnectionProfile.fromJson(entry, ''));
    }
    return out;
  }

  Future<ConnectionProfile> upsert(ConnectionProfile profile) async {
    final payload = profile.toJson();
    payload['password'] = profile.password;
    final result = await _client.request('profile.update', payload);
    final map = result as Map<String, Object?>;
    return ConnectionProfile.fromJson(map, profile.password);
  }

  Future<void> remove(String id) async {
    await _client.request('profile.remove', {'id': id});
  }

  Future<String> password(String id) async {
    final result = await _client.request('profile.password', {'id': id});
    final map = result as Map<String, Object?>;
    return map['password'] as String? ?? '';
  }
}

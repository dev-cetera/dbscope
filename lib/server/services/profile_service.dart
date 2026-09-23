// ProfileService — authoritative store for connection profiles. Loads
// from disk on first use; publishes `profile.changed` whenever the list
// mutates. Password handling stays in SecureStore.
//
// Wire shape for a profile uses the same toJson()/fromJson() as
// ConnectionProfile but adds the password in a separate field because the
// JSON encoded form deliberately omits it.

import '../../connection/profile.dart';
import '../../connection/profile_store.dart';
import '../../connection/secure_store.dart';
import '../../rpc/envelope.dart';
import '../server.dart';
import 'bus_service.dart';

class ProfileService {
  final ProfileStore _store;
  final SecureStore _secure;
  final BusService _bus;

  List<ConnectionProfile> _profiles = const [];
  bool _loaded = false;

  ProfileService({
    ProfileStore? store,
    SecureStore? secure,
    required BusService bus,
  }) : _store = store ?? ProfileStore.instance,
       _secure = secure ?? SecureStore.instance,
       _bus = bus;

  void register(Server server) {
    server.onRequest('profile.list', (_) async => _listJson());
    server.onRequest('profile.add', (p) async {
      _ensureMap(p);
      final profile = _fromParams(p as Map<String, Object?>);
      await _upsert(profile);
      return _toJson(profile);
    });
    server.onRequest('profile.update', (p) async {
      _ensureMap(p);
      final profile = _fromParams(p as Map<String, Object?>);
      await _upsert(profile);
      return _toJson(profile);
    });
    server.onRequest('profile.remove', (p) async {
      _ensureMap(p);
      final id = (p as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      await _remove(id);
      return null;
    });
    server.onRequest('profile.password', (p) async {
      _ensureMap(p);
      final id = (p as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      // Password is only handed back to server-side code that needs it
      // (Connection open). Clients never see it.
      return {'password': await _secure.readPassword(id) ?? ''};
    });
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _profiles = await _store.load();
    _loaded = true;
  }

  Future<List<Object?>> _listJson() async {
    await _ensureLoaded();
    return [for (final p in _profiles) _toJson(p)];
  }

  Future<void> _upsert(ConnectionProfile profile) async {
    await _ensureLoaded();
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles = [..._profiles, profile];
    }
    await _store.save(_profiles);
    _bus.publish('profile.changed', {
      'profiles': [for (final p in _profiles) _toJson(p)],
    });
  }

  Future<void> _remove(String id) async {
    await _ensureLoaded();
    final removed = _profiles.where((p) => p.id == id).toList();
    _profiles = _profiles.where((p) => p.id != id).toList();
    for (final p in removed) {
      await _store.delete(p);
    }
    await _store.save(_profiles);
    _bus.publish('profile.changed', {
      'profiles': [for (final p in _profiles) _toJson(p)],
    });
  }

  // Server-side accessor used by ConnectionService and jobs.
  Future<ConnectionProfile?> resolve(String id) async {
    await _ensureLoaded();
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<List<ConnectionProfile>> all() async {
    await _ensureLoaded();
    return List.unmodifiable(_profiles);
  }

  /// Plugin-initiated upsert. Used when a plugin learns updated state
  /// during open (e.g. a fresh refresh token) and wants it persisted
  /// without going through the client-facing RPC.
  Future<void> upsertFromPlugin(ConnectionProfile profile) async {
    await _upsert(profile);
  }

  Map<String, Object?> _toJson(ConnectionProfile p) => p.toJson();

  ConnectionProfile _fromParams(Map<String, Object?> p) {
    final password = p['password'] as String? ?? '';
    return ConnectionProfile.fromJson(p, password);
  }

  void _ensureMap(Object? p) {
    if (p is! Map<String, Object?>) {
      throw const RpcError('bad_params', 'expected object');
    }
  }
}

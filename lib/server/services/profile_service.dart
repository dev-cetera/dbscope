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
  ProfileService({
    ProfileStore? store,
    SecureStore? secure,
    required this._bus,
  }) : _store = store ?? ProfileStore.instance,
       _secure = secure ?? SecureStore.instance;
  final ProfileStore _store;
  final SecureStore _secure;
  final BusService _bus;

  List<ConnectionProfile> _profiles = const [];
  var _loaded = false;

  void register(Server server) {
    server.onRequest('profile.list', (_) async => _listJson());
    server.onRequest('profile.add', (rawParams) async {
      _ensureMap(rawParams);
      final profile = _fromParams(rawParams! as Map<String, Object?>);
      await _upsert(profile);
      return _toJson(profile);
    });
    server.onRequest('profile.update', (rawParams) async {
      _ensureMap(rawParams);
      final profile = _fromParams(rawParams! as Map<String, Object?>);
      await _upsert(profile);
      return _toJson(profile);
    });
    server.onRequest('profile.remove', (rawParams) async {
      _ensureMap(rawParams);
      final id = (rawParams! as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      await _remove(id);
      return null;
    });
    server.onRequest('profile.password', (rawParams) async {
      _ensureMap(rawParams);
      final id = (rawParams! as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      // Handed back only on demand to whoever opens a connection — the
      // server's ConnectionService and each window's ConnectionRegistry.
      // profile.list never includes it.
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
    return [for (final profile in _profiles) _toJson(profile)];
  }

  Future<void> _upsert(ConnectionProfile profile) async {
    await _ensureLoaded();
    final index = _profiles.indexWhere((stored) => stored.id == profile.id);
    if (index >= 0) {
      // Window-side profiles carry `password: ''` (see profile.list), so a
      // settings-only update (read-only, tenant filter, metadata) arrives
      // blank. Keep the stored password — ProfileStore.save already skips
      // empty passwords, so this just keeps memory in step with the
      // keychain instead of handing jobs an empty password until restart.
      _profiles[index] = profile.password.isEmpty
          ? profile.copyWith(password: _profiles[index].password)
          : profile;
    } else {
      _profiles = [..._profiles, profile];
    }
    await _store.save(_profiles);
    _bus.publish('profile.changed', {
      'profiles': [for (final stored in _profiles) _toJson(stored)],
    });
  }

  Future<void> _remove(String id) async {
    await _ensureLoaded();
    final removed = _profiles.where((profile) => profile.id == id).toList();
    _profiles = _profiles.where((profile) => profile.id != id).toList();
    for (final profile in removed) {
      await _store.delete(profile);
    }
    await _store.save(_profiles);
    _bus.publish('profile.changed', {
      'profiles': [for (final profile in _profiles) _toJson(profile)],
    });
  }

  // Server-side accessor used by ConnectionService and jobs.
  Future<ConnectionProfile?> resolve(String id) async {
    await _ensureLoaded();
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
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

  Map<String, Object?> _toJson(ConnectionProfile profile) => profile.toJson();

  ConnectionProfile _fromParams(Map<String, Object?> params) {
    final password = params['password'] as String? ?? '';
    return ConnectionProfile.fromJson(params, password);
  }

  void _ensureMap(Object? rawParams) {
    if (rawParams is! Map<String, Object?>) {
      throw const RpcError('bad_params', 'expected object');
    }
  }
}

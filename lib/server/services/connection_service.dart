// ConnectionService — server-side owner of DbExecutor objects.
// Clients ask to open/close, query state, and listen for state changes.
// Server-side code (jobs) calls `obtain(profileId)` to use a connection
// directly without going through the RPC surface.
//
// The actual backend (Postgres TCP, an HTTP-mediated SQL API, etc.) is
// decided by the profile's `kind` and the ConnectionKindPlugin registered
// for that kind.

import 'dart:async';

import '../../db/executor.dart';
import '../../db/plugin.dart';
import '../../rpc/envelope.dart';
import '../server.dart';
import 'bus_service.dart';
import 'profile_service.dart';

enum ConnectionState { disconnected, connecting, connected, error }

class _ConnEntry {
  _ConnEntry({required this.readOnly});
  ConnectionState state = ConnectionState.disconnected;
  DbExecutor? executor;
  String? lastError;
  bool readOnly;
}

class ConnectionService {
  ConnectionService({required ProfileService profiles, required BusService bus})
    : _profiles = profiles,
      _bus = bus;
  final ProfileService _profiles;
  final BusService _bus;
  final Map<String, _ConnEntry> _entries = {};

  void register(Server server) {
    server.onRequest('connection.open', (rawParams) async {
      final id = _idFrom(rawParams);
      await _open(id);
      return _state(id);
    });
    server.onRequest('connection.close', (rawParams) async {
      final id = _idFrom(rawParams);
      await _close(id);
      return _state(id);
    });
    server.onRequest('connection.state', (rawParams) async {
      final id = _idFrom(rawParams);
      return _state(id);
    });
    server.onRequest('connection.setReadOnly', (rawParams) async {
      _ensureMap(rawParams);
      final params = rawParams! as Map<String, Object?>;
      final id = params['id'] as String?;
      final ro = params['readOnly'] as bool?;
      if (id == null || ro == null) {
        throw const RpcError('bad_params', 'id+readOnly required');
      }
      await _setReadOnly(id, ro);
      return _state(id);
    });
  }

  // Server-side handle to a live connection. Opens lazily if needed.
  Future<DbExecutor> obtain(String profileId) async {
    final entry = _entries[profileId];
    if (entry?.executor?.isOpen ?? false) return entry!.executor!;
    await _open(profileId);
    final fresh = _entries[profileId];
    final executor = fresh?.executor;
    if (executor == null || !executor.isOpen) {
      throw RpcError('not_connected', fresh?.lastError ?? 'connection failed');
    }
    return executor;
  }

  bool isOpen(String profileId) =>
      _entries[profileId]?.executor?.isOpen ?? false;
  bool isReadOnly(String profileId) => _entries[profileId]?.readOnly ?? false;

  Future<void> _open(String profileId) async {
    final profile = await _profiles.resolve(profileId);
    if (profile == null) {
      throw RpcError('unknown_profile', profileId);
    }
    var entry = _entries[profileId];
    entry ??= _ConnEntry(readOnly: profile.readOnly);
    _entries[profileId] = entry;
    if (entry.executor?.isOpen ?? false) return;
    entry.state = ConnectionState.connecting;
    entry.lastError = null;
    _publishState(profileId);
    try {
      final plugin = ConnectionKindRegistry.instance.lookup(profile.kind);
      if (plugin == null) {
        throw RpcError(
          'no_plugin',
          'no plugin registered for kind "${profile.kind}"',
        );
      }
      final opened = await plugin.open(profile);
      if (opened.updatedProfile != null) {
        await _profiles.upsertFromPlugin(opened.updatedProfile!);
      }
      if (entry.readOnly && opened.executor.capabilities.sessionReadOnly) {
        await opened.executor.setReadOnly(readOnly: true);
      }
      entry.executor = opened.executor;
      entry.state = ConnectionState.connected;
    } catch (e) {
      entry.executor = null;
      entry.state = ConnectionState.error;
      entry.lastError = e.toString();
      _publishState(profileId);
      throw RpcError('connect_failed', entry.lastError!);
    } finally {
      _publishState(profileId);
    }
  }

  Future<void> _close(String profileId) async {
    final entry = _entries[profileId];
    if (entry == null) return;
    final executor = entry.executor;
    entry.executor = null;
    entry.state = ConnectionState.disconnected;
    if (executor != null) {
      try {
        await executor.close();
      } catch (_) {}
    }
    _publishState(profileId);
  }

  Future<void> _setReadOnly(String profileId, bool ro) async {
    final entry = _entries[profileId];
    if (entry == null) {
      // not opened yet — remember the preference for next open
      _entries[profileId] = _ConnEntry(readOnly: ro);
      return;
    }
    entry.readOnly = ro;
    final executor = entry.executor;
    if (executor != null &&
        executor.isOpen &&
        executor.capabilities.sessionReadOnly) {
      await executor.setReadOnly(readOnly: ro);
    }
  }

  Future<void> closeAll() async {
    for (final id in _entries.keys.toList()) {
      await _close(id);
    }
  }

  Map<String, Object?> _state(String profileId) {
    final entry = _entries[profileId];
    return {
      'id': profileId,
      'state': (entry?.state ?? ConnectionState.disconnected).name,
      'readOnly': entry?.readOnly ?? false,
      if (entry?.lastError != null) 'error': entry!.lastError,
    };
  }

  void _publishState(String profileId) {
    _bus.publish('connection.state:$profileId', _state(profileId));
  }

  String _idFrom(Object? rawParams) {
    _ensureMap(rawParams);
    final id = (rawParams! as Map<String, Object?>)['id'] as String?;
    if (id == null) {
      throw const RpcError('bad_params', 'id required');
    }
    return id;
  }

  void _ensureMap(Object? rawParams) {
    if (rawParams is! Map<String, Object?>) {
      throw const RpcError('bad_params', 'expected object');
    }
  }
}

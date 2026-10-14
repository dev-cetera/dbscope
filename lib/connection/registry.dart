/// @docImport '../query/runner.dart';
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../catalog/dbml_cache.dart';
import '../db/executor.dart';
import '../db/plugin.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_settings.dart';
import '../rpc/backend_client.dart';
import '../rpc/services/bus_client.dart';
import '../rpc/services/profile_client.dart';
import '../shell/ui_prefs.dart';
import 'profile.dart';

class _ConnState {
  _ConnState(this.profile) : isReadOnlyOverride = profile.readOnly;
  ConnectionProfile profile;
  DbExecutor? executor;
  var isConnecting = false;
  bool isReadOnlyOverride;
  String? lastError;

  bool get isConnected => executor?.isOpen ?? false;
  bool get effectiveReadOnly => isReadOnlyOverride;
}

// ConnectionRegistry is per-window. It owns this window's DbExecutor
// objects but delegates profile state to the server via RPC. Profile
// mutations from any window propagate back here via the `profile.changed`
// bus event. Postgres profiles open their own TCP connection here;
// non-Postgres kinds delegate to whichever plugin owns the kind — they
// may run a per-window executor or proxy to the host, that's the plugin's
// call.
class ConnectionRegistry extends ChangeNotifier {
  ConnectionRegistry._();
  static final instance = ConnectionRegistry._();

  ProfileServiceClient? _profileClient;
  BusClient? _busClient;
  StreamSubscription<BusEvent>? _profileSub;
  StreamSubscription<BusEvent>? _metaSub;

  /// Identifies this window on the bus so it ignores its own
  /// `meta.changed` broadcasts.
  final _windowNonce =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  final Map<String, _ConnState> _states = {};
  final List<ConnectionProfile> _profiles = [];
  String? _activeId;

  List<ConnectionProfile> get profiles => List.unmodifiable(_profiles);
  String? get activeId => _activeId;
  ConnectionProfile? get profile =>
      _activeId == null ? null : _states[_activeId]?.profile;
  DbExecutor? get connection =>
      _activeId == null ? null : _states[_activeId]?.executor;
  bool get isConnected =>
      !(_activeId == null) && (_states[_activeId]?.isConnected ?? false);
  bool get isConnecting =>
      !(_activeId == null) && (_states[_activeId]?.isConnecting ?? false);
  String? get lastError =>
      _activeId == null ? null : _states[_activeId]?.lastError;
  bool get isReadOnly =>
      !(_activeId == null) && (_states[_activeId]?.effectiveReadOnly ?? false);

  DbExecutor? connectionFor(String profileId) => _states[profileId]?.executor;

  /// Whether [profileId]'s connection is in read-only mode.
  bool isReadOnlyFor(String profileId) =>
      _states[profileId]?.effectiveReadOnly ?? false;

  /// Return [id]'s profile with its stored password populated (from the
  /// server-side keychain). Used by connection-link export, which needs a
  /// self-contained profile. Returns null if the profile is unknown.
  Future<ConnectionProfile?> profileWithPassword(String id) async {
    final profile = _states[id]?.profile ?? profileById(id);
    if (profile == null) return null;
    if (profile.password.isNotEmpty) return profile;
    final client = _profileClient;
    if (client == null) return profile;
    try {
      final pw = await client.password(id);
      return pw.isEmpty ? profile : profile.copyWith(password: pw);
    } catch (_) {
      return profile;
    }
  }

  ConnectionProfile? profileById(String id) =>
      _profiles.cast<ConnectionProfile?>().firstWhere(
        (profile) => profile?.id == id,
        orElse: () => null,
      );

  // Bind to a backend. Must be called once at startup, before load().
  void bind({required BackendClient client}) {
    _profileClient = ProfileServiceClient(client);
    _busClient = BusClient(client);
    unawaited(_profileSub?.cancel());
    _profileSub = _busClient!
        .subscribe('profile.changed')
        .listen(_onProfileEvent);
    unawaited(_metaSub?.cancel());
    // BusService wildcards only match a `.*` suffix, so subscribe to
    // `meta.*` and filter for `meta.changed:<profileId>` here.
    _metaSub = _busClient!.subscribe('meta.*').listen(_onMetaEvent);
    MetadataCache.instance.onReloadedBroadcast = (profileId) async {
      try {
        await _busClient?.publish('meta.changed:$profileId', {
          'origin': _windowNonce,
        });
      } catch (_) {
        // Other windows reload on their next connect anyway.
      }
    };
  }

  /// Another window reloaded metadata: reload this window's copy (and the
  /// DBML built from it) without re-broadcasting.
  void _onMetaEvent(BusEvent event) {
    const prefix = 'meta.changed:';
    if (!event.topic.startsWith(prefix)) return;
    if (event.dataAsMap?['origin'] == _windowNonce) return;
    final profileId = event.topic.substring('meta.changed:'.length);
    if (_states[profileId]?.executor == null) return;
    unawaited(_reloadMetadata(profileId, broadcast: false));
  }

  /// Reloads schema metadata for [profileId] and rebuilds the DBML cache
  /// (which carries descriptions and respects access control).
  Future<void> reloadMetadata(String profileId) =>
      _reloadMetadata(profileId, broadcast: true);

  Future<void> _reloadMetadata(
    String profileId, {
    required bool broadcast,
  }) async {
    final executor = _states[profileId]?.executor;
    if (executor == null) return;
    await MetadataCache.instance.reload(profileId, broadcast: broadcast);
    DbmlCache.instance.invalidate(profileId);
    DbmlCache.instance.warm(profileId, executor);
    notifyListeners();
  }

  void _onProfileEvent(BusEvent event) {
    final data = event.dataAsMap;
    if (data == null) return;
    final list = data['profiles'] as List<Object?>? ?? const [];
    final fresh = <ConnectionProfile>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      fresh.add(ConnectionProfile.fromJson(entry, ''));
    }
    _mergeProfiles(fresh);
    notifyListeners();
  }

  void _mergeProfiles(List<ConnectionProfile> fresh) {
    _profiles
      ..clear()
      ..addAll(fresh);
    // Drop states whose profile vanished.
    final keep = _profiles.map((profile) => profile.id).toSet();
    _states.removeWhere((id, _) => !keep.contains(id));
    // Update existing states; create new ones so switching to a saved
    // profile actually has somewhere to open a connection from.
    for (final freshProfile in fresh) {
      final state = _states[freshProfile.id];
      if (state != null) {
        // If another window flipped readOnly on a profile we have open,
        // re-apply it to the executor here so this window stops issuing
        // writes (or starts allowing them) without needing a reconnect.
        final readOnlyChanged =
            state.isReadOnlyOverride != freshProfile.readOnly;
        final metadataChanged =
            state.profile.metadata.toJson().toString() !=
            freshProfile.metadata.toJson().toString();
        state.profile = freshProfile;
        if (metadataChanged && state.executor != null) {
          final executor = state.executor!;
          unawaited(
            MetadataCache.instance.profileChanged(freshProfile).then((_) {
              DbmlCache.instance.invalidate(freshProfile.id);
              DbmlCache.instance.warm(freshProfile.id, executor);
              notifyListeners();
            }),
          );
        }
        if (readOnlyChanged) {
          state.isReadOnlyOverride = freshProfile.readOnly;
          final executor = state.executor;
          if (executor != null &&
              executor.isOpen &&
              executor.capabilities.sessionReadOnly) {
            unawaited(executor.setReadOnly(readOnly: freshProfile.readOnly));
          }
        }
      } else {
        _states[freshProfile.id] = _ConnState(freshProfile);
      }
    }
    if (_activeId != null && !keep.contains(_activeId)) {
      _activeId = null;
    }
  }

  Future<void> load() async {
    final client = _profileClient;
    if (client == null) {
      // bind() hasn't run yet — bail without flagging loaded so a later
      // load() can succeed.
      return;
    }
    try {
      final loaded = await client.list();
      _mergeProfiles(loaded);
    } catch (e, st) {
      // Surface errors instead of silently leaving the picker empty.
      debugPrint('ConnectionRegistry.load failed: $e\n$st');
    }
    notifyListeners();
  }

  /// Forces a re-fetch from the backend. Use from UI when the picker
  /// shows fewer profiles than expected.
  Future<void> reloadProfiles() => load();

  Future<void> addProfile(ConnectionProfile profile) async {
    final client = _profileClient;
    if (client == null) return;
    final stored = await client.upsert(profile);
    final cached = stored.password.isEmpty
        ? ConnectionProfile.fromJson(stored.toJson(), profile.password)
        : stored;
    final existing = _profiles.indexWhere(
      (profile) => profile.id == cached.id,
    );
    if (existing >= 0) {
      _profiles[existing] = cached;
    } else {
      _profiles.add(cached);
    }
    final state = _states[cached.id];
    if (state != null) {
      state.profile = cached;
    } else {
      _states[cached.id] = _ConnState(cached);
    }
    notifyListeners();
  }

  Future<void> updateProfile(ConnectionProfile profile) async {
    await addProfile(profile);
  }

  Future<void> removeProfile(String id) async {
    final client = _profileClient;
    if (client == null) return;
    await _closeState(_states[id]);
    _states.remove(id);
    _profiles.removeWhere((profile) => profile.id == id);
    if (_activeId == id) _activeId = null;
    DbmlCache.instance.invalidate(id);
    MetadataCache.instance.invalidate(id);
    try {
      await client.remove(id);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setActive(String? id, {BuildContext? context}) async {
    if (id == _activeId) return;
    _activeId = id;
    if (id != null) {
      UiPrefs.instance.setLastConnectionId(id);
    }
    notifyListeners();
    if (id != null) {
      final state = _states[id];
      if (state != null && !state.isConnected && !state.isConnecting) {
        await connectActive(context: context);
      }
    }
  }

  Future<void> connectActive({BuildContext? context}) async {
    final id = _activeId;
    if (id == null) return;
    final state = _states[id];
    if (state == null) return;
    await _connect(state, context: context);
  }

  Future<void> connectProfile(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    await addProfile(profile);
    if (context != null && !context.mounted) {
      await setActive(profile.id);
      await connectActive();
      return;
    }
    await setActive(profile.id, context: context);
    if (context != null && !context.mounted) {
      await connectActive();
      return;
    }
    await connectActive(context: context);
  }

  Future<void> _connect(_ConnState state, {BuildContext? context}) async {
    if (state.isConnecting) return;
    state.isConnecting = true;
    state.lastError = null;
    notifyListeners();
    try {
      var profile = state.profile;
      final plugin = ConnectionKindRegistry.instance.lookup(profile.kind);
      if (plugin == null) {
        throw StateError(
          'No connection-kind plugin registered for "${profile.kind}"',
        );
      }
      // Profiles arrive from the server without passwords; load the stored
      // one lazily when the in-memory profile doesn't carry it. Kinds that
      // keep their secrets in `extra` (pg-proxy, sqflite) simply have
      // nothing stored here, so this is a harmless no-op for them.
      if (profile.password.isEmpty && _profileClient != null) {
        final pw = await _profileClient!.password(profile.id);
        if (pw.isNotEmpty) {
          profile = profile.copyWith(password: pw);
          state.profile = profile;
        }
      }
      var mountedContext = context;
      if (mountedContext != null && !mountedContext.mounted) {
        mountedContext = null;
      }
      // `mountedContext` was nulled out just above if it unmounted during
      // the awaits.
      // ignore: use_build_context_synchronously
      final opened = await plugin.open(profile, context: mountedContext);
      if (opened.updatedProfile != null) {
        state.profile = opened.updatedProfile!;
        // Persist plugin-driven mutations (e.g. new refresh-token blob).
        try {
          await _profileClient?.upsert(opened.updatedProfile!);
        } catch (_) {}
      }
      if (state.effectiveReadOnly &&
          opened.executor.capabilities.sessionReadOnly) {
        await opened.executor.setReadOnly(readOnly: true);
      }
      // Schema metadata (descriptions, access control, …) loads before the
      // connection is marked connected: the catalog filters through the
      // access policy, so loading it first means hidden tables never flash
      // into the sidebar. It is a handful of catalog queries, run together.
      try {
        await MetadataCache.instance.load(state.profile, opened.executor);
      } catch (_) {
        // Don't leak the socket / Cloud SQL proxy ref of a connection that
        // never becomes `state.executor`.
        await opened.executor.close();
        rethrow;
      }
      state.executor = opened.executor;
      // Warm the DBML cache in the background so DBML export and the AI
      // SQL assistant have a ready schema without paying for a fresh
      // round-trip walk every time.
      DbmlCache.instance.warm(state.profile.id, opened.executor);
    } catch (e) {
      state.lastError = e.toString();
      state.executor = null;
    } finally {
      state.isConnecting = false;
      notifyListeners();
    }
  }

  Future<void> _closeState(_ConnState? state) async {
    if (state == null) return;
    final executor = state.executor;
    state.executor = null;
    if (executor != null) {
      try {
        await executor.close();
      } catch (_) {}
    }
  }

  Future<void> disconnect([String? profileId]) async {
    final id = profileId ?? _activeId;
    if (id == null) return;
    await _closeState(_states[id]);
    notifyListeners();
  }

  Future<void> killConnection([String? profileId]) async {
    final id = profileId ?? _activeId;
    if (id == null) return;
    final state = _states[id];
    if (state == null) return;
    final executor = state.executor;
    state.executor = null;
    if (executor != null) {
      try {
        await executor.close(force: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Replace the per-table overrides for one (schema, table) on a
  /// profile and broadcast the change to other windows. Passing null
  /// removes the entry, keeping the persisted JSON tight. Does not
  /// reconnect — the next [TableLoader.loadTable] call picks up the
  /// new value.
  Future<void> setTableOverride(
    String profileId,
    String schema,
    String table,
    TableOverrides? overrides,
  ) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) return;
    final updated = _profiles[index].withTableOverride(
      schema,
      table,
      overrides,
    );
    _profiles[index] = updated;
    final state = _states[profileId];
    if (state != null) state.profile = updated;
    if (_profileClient != null) {
      try {
        await _profileClient!.upsert(updated);
      } catch (_) {}
    }
    // Profile overrides are the top metadata layer (soft-delete column).
    if (state?.executor != null) {
      await MetadataCache.instance.profileChanged(updated);
    }
    notifyListeners();
  }

  /// Replace the profile's tenant filter and broadcast. Passing null
  /// clears it.
  Future<void> setTenantFilter(
    String profileId,
    TenantFilter? filter,
  ) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) return;
    final updated = _profiles[index].copyWith(tenantFilter: filter);
    _profiles[index] = updated;
    final state = _states[profileId];
    if (state != null) state.profile = updated;
    if (_profileClient != null) {
      try {
        await _profileClient!.upsert(updated);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> setReadOnly(String profileId, {required bool readOnly}) async {
    final state = _states[profileId];
    if (state == null) return;
    state.isReadOnlyOverride = readOnly;
    final executor = state.executor;
    if (executor != null &&
        executor.isOpen &&
        executor.capabilities.sessionReadOnly) {
      await executor.setReadOnly(readOnly: readOnly);
    }
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index >= 0) {
      final updated = _profiles[index].copyWith(readOnly: readOnly);
      _profiles[index] = updated;
      state.profile = updated;
      // Push back to server so other windows see it.
      if (_profileClient != null) {
        try {
          await _profileClient!.upsert(updated);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    for (final state in _states.values) {
      await _closeState(state);
    }
    _activeId = null;
    unawaited(_profileSub?.cancel());
    _profileSub = null;
    unawaited(_metaSub?.cancel());
    _metaSub = null;
    notifyListeners();
  }

  /// Replace the profile's metadata settings and broadcast; the metadata
  /// reloads in every window through the profile.changed path.
  Future<void> setMetadataSettings(
    String profileId,
    MetadataSettings settings,
  ) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) return;
    final updated = _profiles[index].copyWith(metadata: settings);
    _profiles[index] = updated;
    final state = _states[profileId];
    if (state != null) state.profile = updated;
    if (_profileClient != null) {
      try {
        await _profileClient!.upsert(updated);
      } catch (_) {}
    }
    final executor = state?.executor;
    if (executor != null) {
      await MetadataCache.instance.profileChanged(updated);
      DbmlCache.instance.invalidate(profileId);
      DbmlCache.instance.warm(profileId, executor);
    }
    notifyListeners();
  }
}

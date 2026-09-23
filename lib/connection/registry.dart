import 'dart:async';

import 'package:flutter/widgets.dart';

import '../catalog/dbml_cache.dart';
import '../db/executor.dart';
import '../db/plugin.dart';
import '../rpc/backend_client.dart';
import '../rpc/services/bus_client.dart';
import '../rpc/services/profile_client.dart';
import '../shell/ui_prefs.dart';
import 'profile.dart';

class _ConnState {
  ConnectionProfile profile;
  DbExecutor? executor;
  bool isConnecting = false;
  bool isReadOnlyOverride;
  String? lastError;

  _ConnState(this.profile) : isReadOnlyOverride = profile.readOnly;

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
  static final ConnectionRegistry instance = ConnectionRegistry._();

  ProfileServiceClient? _profileClient;
  BusClient? _busClient;
  StreamSubscription<BusEvent>? _profileSub;

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
      _activeId == null ? false : (_states[_activeId]?.isConnected ?? false);
  bool get isConnecting =>
      _activeId == null ? false : (_states[_activeId]?.isConnecting ?? false);
  String? get lastError =>
      _activeId == null ? null : _states[_activeId]?.lastError;
  bool get isReadOnly => _activeId == null
      ? false
      : (_states[_activeId]?.effectiveReadOnly ?? false);

  DbExecutor? connectionFor(String profileId) => _states[profileId]?.executor;

  /// Return [id]'s profile with its stored password populated (from the
  /// server-side keychain). Used by connection-link export, which needs a
  /// self-contained profile. Returns null if the profile is unknown.
  Future<ConnectionProfile?> profileWithPassword(String id) async {
    final p = _states[id]?.profile ?? profileById(id);
    if (p == null) return null;
    if (p.password.isNotEmpty) return p;
    final client = _profileClient;
    if (client == null) return p;
    try {
      final pw = await client.password(id);
      return pw.isEmpty ? p : p.copyWith(password: pw);
    } catch (_) {
      return p;
    }
  }

  ConnectionProfile? profileById(String id) =>
      _profiles.cast<ConnectionProfile?>().firstWhere(
        (p) => p?.id == id,
        orElse: () => null,
      );

  // Bind to a backend. Must be called once at startup, before load().
  void bind({required BackendClient client}) {
    _profileClient = ProfileServiceClient(client);
    _busClient = BusClient(client);
    _profileSub?.cancel();
    _profileSub = _busClient!
        .subscribe('profile.changed')
        .listen(_onProfileEvent);
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
    final keep = _profiles.map((p) => p.id).toSet();
    _states.removeWhere((id, _) => !keep.contains(id));
    // Update existing states; create new ones so switching to a saved
    // profile actually has somewhere to open a connection from.
    for (final p in fresh) {
      final s = _states[p.id];
      if (s != null) {
        // If another window flipped readOnly on a profile we have open,
        // re-apply it to the executor here so this window stops issuing
        // writes (or starts allowing them) without needing a reconnect.
        final readOnlyChanged = s.isReadOnlyOverride != p.readOnly;
        s.profile = p;
        if (readOnlyChanged) {
          s.isReadOnlyOverride = p.readOnly;
          final exec = s.executor;
          if (exec != null &&
              exec.isOpen &&
              exec.capabilities.sessionReadOnly) {
            unawaited(exec.setReadOnly(p.readOnly));
          }
        }
      } else {
        _states[p.id] = _ConnState(p);
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
    final existing = _profiles.indexWhere((p) => p.id == cached.id);
    if (existing >= 0) {
      _profiles[existing] = cached;
    } else {
      _profiles.add(cached);
    }
    final s = _states[cached.id];
    if (s != null) {
      s.profile = cached;
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
    _profiles.removeWhere((p) => p.id == id);
    if (_activeId == id) _activeId = null;
    DbmlCache.instance.invalidate(id);
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
      BuildContext? ctx = context;
      if (ctx != null && !ctx.mounted) ctx = null;
      // ignore: use_build_context_synchronously
      final opened = await plugin.open(profile, context: ctx);
      if (opened.updatedProfile != null) {
        state.profile = opened.updatedProfile!;
        // Persist plugin-driven mutations (e.g. new refresh-token blob).
        try {
          await _profileClient?.upsert(opened.updatedProfile!);
        } catch (_) {}
      }
      if (state.effectiveReadOnly &&
          opened.executor.capabilities.sessionReadOnly) {
        await opened.executor.setReadOnly(true);
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
    final c = state.executor;
    state.executor = null;
    if (c != null) {
      try {
        await c.close();
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
    final c = state.executor;
    state.executor = null;
    if (c != null) {
      try {
        await c.close(force: true);
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
    final idx = _profiles.indexWhere((p) => p.id == profileId);
    if (idx < 0) return;
    final updated = _profiles[idx].withTableOverride(schema, table, overrides);
    _profiles[idx] = updated;
    final state = _states[profileId];
    if (state != null) state.profile = updated;
    if (_profileClient != null) {
      try {
        await _profileClient!.upsert(updated);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Replace the profile's tenant filter and broadcast. Passing null
  /// clears it.
  Future<void> setTenantFilter(
    String profileId,
    TenantFilter? filter,
  ) async {
    final idx = _profiles.indexWhere((p) => p.id == profileId);
    if (idx < 0) return;
    final updated = _profiles[idx].copyWith(tenantFilter: filter);
    _profiles[idx] = updated;
    final state = _states[profileId];
    if (state != null) state.profile = updated;
    if (_profileClient != null) {
      try {
        await _profileClient!.upsert(updated);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> setReadOnly(String profileId, bool ro) async {
    final state = _states[profileId];
    if (state == null) return;
    state.isReadOnlyOverride = ro;
    final exec = state.executor;
    if (exec != null && exec.isOpen && exec.capabilities.sessionReadOnly) {
      await exec.setReadOnly(ro);
    }
    final idx = _profiles.indexWhere((p) => p.id == profileId);
    if (idx >= 0) {
      final updated = _profiles[idx].copyWith(readOnly: ro);
      _profiles[idx] = updated;
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
    for (final s in _states.values) {
      await _closeState(s);
    }
    _activeId = null;
    _profileSub?.cancel();
    _profileSub = null;
    notifyListeners();
  }
}

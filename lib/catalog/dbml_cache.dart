// Per-profile DBML cache.
//
// The DBML generator does ~3 queries per table; on an HTTP-mediated
// backend that's tens of round-trips. We do it once per connect, in
// the background, and reuse the result for:
// - the File ▸ Export schema as DBML… flow
// - the AI SQL assistant's schema context
//
// Cache key: profileId. Invalidates on profile delete / reconnect via
// `invalidate(profileId)`; otherwise lives for the app lifetime.
//
// Concurrency: an in-flight future is shared so two callers asking at
// the same time don't trigger two generations.
//
// Listenable: the cache extends ChangeNotifier so UI that gates on
// readiness (Ask AI button, navigator AI Infer) rebuilds when warm
// completes. Status is a real tri-state — a failed warm stays as
// `failed` so the UI can surface a retry affordance instead of being
// stuck on "warming forever".

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/executor.dart';
import 'dbml_export.dart';

enum DbmlStatus { none, pending, ready, failed }

class _CacheEntry {
  final String? dbml;
  final Future<String>? inFlight;
  final Object? error;
  const _CacheEntry._({this.dbml, this.inFlight, this.error});
  const _CacheEntry.ready(String value) : this._(dbml: value);
  const _CacheEntry.pending(Future<String> future) : this._(inFlight: future);
  const _CacheEntry.failed(Object err) : this._(error: err);

  DbmlStatus get status {
    if (dbml != null) return DbmlStatus.ready;
    if (inFlight != null) return DbmlStatus.pending;
    if (error != null) return DbmlStatus.failed;
    return DbmlStatus.none;
  }
}

class DbmlCache extends ChangeNotifier {
  DbmlCache._();
  static final DbmlCache instance = DbmlCache._();

  final Map<String, _CacheEntry> _entries = {};

  /// Returns the cached DBML for [profileId], generating it via
  /// [exec] if not present. Concurrent calls share the same in-flight
  /// future. Throws if generation fails.
  Future<String> get(
    String profileId,
    DbExecutor exec, {
    String databaseName = 'dbscope',
  }) {
    final existing = _entries[profileId];
    if (existing?.dbml != null) return Future.value(existing!.dbml!);
    if (existing?.inFlight != null) return existing!.inFlight!;
    return _generate(profileId, exec, databaseName);
  }

  /// Fire-and-forget warm-up — used at connection time so the cache is
  /// ready before the user opens AI or DBML export. Failures keep the
  /// entry as `failed` so the UI can show an error state.
  void warm(
    String profileId,
    DbExecutor exec, {
    String databaseName = 'dbscope',
  }) {
    final existing = _entries[profileId];
    if (existing?.dbml != null || existing?.inFlight != null) return;
    _generate(
      profileId,
      exec,
      databaseName,
    ).catchError((_) => ''); // swallow at the warm callsite
  }

  /// Returns the cached value if present, else null. Used by callers
  /// that want to render fast without blocking on generation.
  String? peek(String profileId) => _entries[profileId]?.dbml;

  DbmlStatus statusFor(String profileId) =>
      _entries[profileId]?.status ?? DbmlStatus.none;

  /// Pending future for [profileId], or null if not pending. Lets the
  /// AI Infer flow await an in-progress warm instead of telling the
  /// user "schema not ready" while it's loading.
  Future<String>? pendingFuture(String profileId) =>
      _entries[profileId]?.inFlight;

  Object? errorFor(String profileId) => _entries[profileId]?.error;

  void invalidate(String profileId) {
    final had = _entries.remove(profileId);
    if (had != null) notifyListeners();
  }

  Future<String> _generate(
    String profileId,
    DbExecutor exec,
    String databaseName,
  ) async {
    // Future is constructed eagerly so we can store it as `inFlight`
    // before any await suspends us.
    late final Future<String> future;
    future = () async {
      try {
        final dbml = await DbmlExporter(
          exec,
          databaseName: databaseName,
        ).generate();
        _entries[profileId] = _CacheEntry.ready(dbml);
        notifyListeners();
        return dbml;
      } catch (e) {
        _entries[profileId] = _CacheEntry.failed(e);
        notifyListeners();
        rethrow;
      }
    }();
    _entries[profileId] = _CacheEntry.pending(future);
    notifyListeners();
    return future;
  }
}

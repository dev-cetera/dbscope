// Contract: MetadataCache.load completes, and concurrent loads for one
// profile share a single load. Regression guard for a self-deadlock where
// the in-flight bookkeeping (`whenComplete(() => map.remove(id))`) made
// the load future wait on itself — the connection registry awaits this
// load on every connect, so it froze connecting entirely.

import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/meta/meta_cache.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_executor.dart';

void main() {
  test('load completes and stores a ready snapshot', () async {
    final exec = FakeDbExecutor();
    final profile = ConnectionProfile(id: 'cache-test', name: 'cache test');
    await MetadataCache.instance
        .load(profile, exec)
        .timeout(const Duration(seconds: 5));
    final snapshot = MetadataCache.instance.snapshotFor('cache-test')!;
    expect(snapshot.status, MetaLoadStatus.ready);
    expect(snapshot.tablesOutcome, MetaTablesOutcome.absent);
    expect(snapshot.policy.active, isFalse);
    expect(MetadataCache.instance.snapshotForExecutor(exec), same(snapshot));
  });

  test('concurrent loads share one in-flight load', () async {
    final exec = FakeDbExecutor();
    final profile = ConnectionProfile(id: 'cache-test-2', name: 'cache test');
    await Future.wait([
      MetadataCache.instance.load(profile, exec),
      MetadataCache.instance.load(profile, exec),
    ]).timeout(const Duration(seconds: 5));
    // A second load after completion starts fresh (not stuck in-flight).
    await MetadataCache.instance
        .load(profile, exec)
        .timeout(const Duration(seconds: 5));
  });
}

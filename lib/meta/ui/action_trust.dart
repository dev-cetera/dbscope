// Trust for SQL that comes from schema metadata (plan.md "Trust").
//
// Metadata stored in a database is code that runs on click, and anyone
// with write access to the metadata can plant some. So nothing from the
// metadata runs SQL until the user trusts it, and trust pins a SHA-256 of
// every SQL-bearing item: any change asks again and marks what changed.
//
// Two scopes, trusted separately:
//   read — read-only actions, named queries, SQL charts, checks and
//          `display.defaultFilter` predicates;
//   exec — write actions.
//
// What trust buys differs by kind. Named queries, charts, checks and query
// actions also run fenced in a read-only transaction (read_only_exec.dart).
// Default filters and `openTable` filters can't be: they become part of the
// grid's own page queries, so for them trust is the only guard — which is
// why they ask for it at all.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../shell/ui_prefs.dart';
import '../meta_index.dart';
import '../meta_models.dart';

enum TrustScope { read, exec }

/// One piece of metadata SQL as shown in the trust dialog.
class TrustItem {
  final String id;
  final String kind;
  final String label;
  final String text;
  const TrustItem({
    required this.id,
    required this.kind,
    required this.label,
    required this.text,
  });

  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode([id, kind, text]))).toString();
}

/// Every SQL-bearing item of [scope] in [index].
List<TrustItem> trustItems(MetaIndex index, TrustScope scope) {
  final out = <TrustItem>[];
  for (final a in index.actions) {
    final isExec = !a.run.isReadOnly;
    if (isExec != (scope == TrustScope.exec)) continue;
    final text = [
      a.target.raw,
      a.run.name,
      ?a.sql,
      ?a.filter,
      ?a.template,
      ?a.table?.raw,
      if (a.expectRows != null) 'expectRows ${a.expectRows}',
    ].join('\n');
    out.add(TrustItem(id: a.id, kind: 'action', label: a.label, text: text));
  }
  if (scope == TrustScope.read) {
    for (final q in index.queries) {
      out.add(TrustItem(id: q.id, kind: 'query', label: q.label, text: q.sql));
    }
    for (final c in index.charts) {
      final source = c.source;
      if (source is ChartSqlSource) {
        out.add(
          TrustItem(id: c.id, kind: 'chart', label: c.label, text: source.sql),
        );
      }
    }
    for (final c in index.checks) {
      out.add(TrustItem(id: c.id, kind: 'check', label: c.label, text: c.sql));
    }
    for (final row in index.document.rowsOfKind(MetaKinds.display)) {
      final filter = specString(row.spec, 'defaultFilter');
      if (filter != null) {
        out.add(
          TrustItem(
            id: row.id,
            kind: 'default filter',
            label: row.target.raw,
            text: filter,
          ),
        );
      }
    }
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}

class MetaTrust {
  static String hashOf(List<TrustItem> items) => sha256
      .convert(utf8.encode([for (final i in items) i.fingerprint].join('\n')))
      .toString();

  /// This window's copy. Subwindows have no SharedPreferences, so without it
  /// a trust given there would be forgotten at once and every run would ask
  /// again (and a trusted default filter would never apply).
  static final Map<String, String> _memory = {};

  static Map<String, Object?> _load(String profileId) {
    final raw = _memory[profileId] ?? UiPrefs.instance.metaTrust(profileId);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
    } catch (_) {
      // A corrupt pin only means "ask again".
    }
    return const {};
  }

  /// True when there is nothing to trust, or the current set was trusted.
  static bool isTrusted(String profileId, MetaIndex index, TrustScope scope) {
    final items = trustItems(index, scope);
    if (items.isEmpty) return true;
    final pinned = _load(profileId)[scope.name];
    return pinned is String && pinned == hashOf(items);
  }

  /// Ids of items new or changed since the last trust. Empty when never
  /// trusted (everything is new then).
  static Set<String> changedSince(
    String profileId,
    MetaIndex index,
    TrustScope scope,
  ) {
    final previous = _load(profileId)['${scope.name}Items'];
    if (previous is! List) return const {};
    final known = previous.whereType<String>().toSet();
    return {
      for (final item in trustItems(index, scope))
        if (!known.contains(item.fingerprint)) item.id,
    };
  }

  static void trust(String profileId, MetaIndex index, TrustScope scope) {
    final items = trustItems(index, scope);
    final current = Map<String, Object?>.of(_load(profileId));
    current[scope.name] = hashOf(items);
    current['${scope.name}Items'] = [for (final i in items) i.fingerprint];
    final encoded = jsonEncode(current);
    _memory[profileId] = encoded;
    UiPrefs.instance.setMetaTrust(profileId, encoded);
  }

  static void revoke(String profileId) {
    _memory.remove(profileId);
    UiPrefs.instance.setMetaTrust(profileId, null);
  }
}

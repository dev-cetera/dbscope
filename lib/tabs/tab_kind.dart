import 'package:flutter/widgets.dart';

import 'tab_model.dart';

/// Builder that turns a [TabModel] into the widget shown in the main area.
typedef TabViewBuilder = Widget Function(TabModel tab);
typedef TabSerializer = Map<String, Object?>? Function(TabModel tab);
typedef TabDeserializer = TabModel? Function(Map<String, Object?> json);
typedef TabPredicate = bool Function(TabModel tab);
typedef TabSummaryBuilder = String? Function(TabModel tab);

/// One kind of tab the app knows how to show. Mirrors the
/// [ConnectionKindPlugin] pattern: instead of every consumer site
/// switching on the concrete [TabModel] subtype, kinds register
/// themselves and the consumers look them up by id or runtime type.
///
/// Adding a new tab kind:
/// 1. Implement a [TabModel] subclass for the persistent state.
/// 2. Implement the view widget.
/// 3. Build a [TabKind] that wires them together.
/// 4. Call [TabKindRegistry.instance.register] from `main.dart`.
class TabKind {
  /// Stable string id used in persisted tab JSON. Never rename — old
  /// serialised tabs would stop deserialising.
  final String id;

  /// Concrete [TabModel] subclass this kind owns. Used to look up the
  /// kind from a live tab via [TabKindRegistry.lookupForTab].
  final Type modelType;

  /// Icon shown in the tab strip. Static today; if a kind wants a
  /// dynamic icon, drop this and add an `iconFor` callback.
  final IconData icon;

  /// Builds the widget shown in the main area for this kind of tab.
  final TabViewBuilder buildView;

  /// Serialises the tab to JSON for session restore. Return null to
  /// opt out — transient kinds (jobs, ad-hoc JSON viewers) do this.
  final TabSerializer? serialize;

  /// Inverse of [serialize]. Required iff [serialize] is set.
  final TabDeserializer? deserialize;

  /// Whether this tab is currently doing work (drives the footer
  /// Cancel button + the global cancel-all). Defaults to "never running".
  final TabPredicate? isRunning;

  /// Short summary line for the footer (e.g. "~12K rows • 47ms").
  /// Returning null defers to the default placeholder.
  final TabSummaryBuilder? footerSummary;

  const TabKind({
    required this.id,
    required this.modelType,
    required this.icon,
    required this.buildView,
    this.serialize,
    this.deserialize,
    this.isRunning,
    this.footerSummary,
  });

  bool get persistent => serialize != null && deserialize != null;
}

/// Process-wide registry of [TabKind]s. main.dart registers each kind
/// before the first frame; no consumer of the registry ever branches on
/// a concrete tab subtype.
class TabKindRegistry {
  TabKindRegistry._();
  static final TabKindRegistry instance = TabKindRegistry._();

  final List<TabKind> _all = [];
  final Map<String, TabKind> _byId = {};
  final Map<Type, TabKind> _byModelType = {};

  void register(TabKind kind) {
    if (_byId.containsKey(kind.id)) {
      _all.removeWhere((k) => k.id == kind.id);
      _byModelType.remove(_byId[kind.id]!.modelType);
    }
    _all.add(kind);
    _byId[kind.id] = kind;
    _byModelType[kind.modelType] = kind;
  }

  TabKind? lookupById(String id) => _byId[id];

  TabKind? lookupForTab(TabModel tab) => _byModelType[tab.runtimeType];

  Iterable<TabKind> get all => List.unmodifiable(_all);
}

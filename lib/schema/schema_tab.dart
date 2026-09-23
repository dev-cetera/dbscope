import 'package:flutter/widgets.dart';
import 'package:schema_viewer/schema_viewer.dart';

import '../catalog/schema_catalog.dart';
import '../tabs/tab_model.dart';

/// Persistent state for the Schema tab. Holds the parsed nodes + edges,
/// the canvas pan/zoom, per-node compact state, the selected node, and
/// the chosen layout mode. Catalog data is loaded eagerly on view init.
class SchemaTab extends TabModel {
  SchemaTab({
    super.id,
    required super.connectionId,
    this.layoutMode = SchemaLayoutMode.lr,
  });

  final List<SchemaNodeData> nodes = [];
  final List<SchemaEdgeData> edges = [];

  /// Catalog-load state. Surfaced in the view so the user sees a
  /// loading placeholder vs. an error banner vs. the diagram itself.
  bool isLoading = false;
  String? error;
  bool isLoaded = false;

  final Map<String, List<ColumnInfo>> _columnCache = {};
  List<ColumnInfo>? cachedColumns(String schema, String table) =>
      _columnCache['$schema.$table'];
  void setCachedColumns(String schema, String table, List<ColumnInfo> cols) {
    _columnCache['$schema.$table'] = cols;
  }

  Offset pan = Offset.zero;
  double scale = 1.0;
  String? selectedId;

  SchemaLayoutMode layoutMode;

  @override
  String get title => 'Schema';
}

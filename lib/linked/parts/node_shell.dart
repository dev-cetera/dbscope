part of '../linked_view.dart';

String _short(Object? v) {
  if (v == null) return 'NULL';
  final s = v.toString();
  if (s.length <= 24) return s;
  return '${s.substring(0, 24)}…';
}

/// Compact "col1=val1, col2=val2" label used by the row picker panel
/// when previewing a row in the seed picker. Kept on the linked-view
/// library so it lives alongside the rest of the row-display helpers.
String _rowLabel(List<Object?> rowVals, List<GridColumnSpec> cols) {
  if (cols.isEmpty) return '(row)';
  return [
    for (var i = 0; i < cols.length; i++)
      '${cols[i].name}=${_short(i < rowVals.length ? rowVals[i] : null)}',
  ].join(', ');
}

/// Subtitle the SchemaCard renders under the table name when a node is
/// a seed: `(pk_col=val, pk_col=val)`. Returns null for non-seed nodes
/// so the card stays compact.
String? _nodeSubtitle(LinkedRowNode n) {
  if (!n.isSeed) return null;
  if (n.pkColumns.isEmpty) return null;
  final parts = <String>[];
  for (var i = 0; i < n.pkColumns.length; i++) {
    final v = i < n.pkValues.length ? n.pkValues[i] : null;
    parts.add('${n.pkColumns[i]}=${_short(v)}');
  }
  return '(${parts.join(', ')})';
}

/// Columns shown in the node body in compact mode — mirrors the filter
/// SchemaCard applies when `compact: true`, so the node-height and
/// edge-anchor math match what's actually rendered.
List<String> _compactColumnsFor(LinkedRowNode node, List<ForeignKey> allFks) {
  if (node.columns.isEmpty) {
    return node.bodyColumnOrder(allFks);
  }
  final pkSet = node.pkColumns.toSet();
  final fkCols = <String>{
    for (final fk in allFks)
      if (fk.fromSchema == node.schema && fk.fromTable == node.table)
        fk.fromColumn,
  };
  final refTargets = <String>{
    for (final fk in allFks)
      if (fk.toSchema == node.schema && fk.toTable == node.table) fk.toColumn,
  };
  return [
    for (final c in node.columns)
      if (pkSet.contains(c.name) ||
          fkCols.contains(c.name) ||
          refTargets.contains(c.name))
        c.name,
  ];
}

/// Convert a LinkedRowNode into a SchemaNodeData the shared SchemaCard
/// can render. Fields are derived from the node's loaded column list,
/// with PK / FK / isRefTarget flags taken from the tab's foreign-key
/// catalog. The card renders in compact mode (PK + FK + ref-target rows
/// only) — full-row data is surfaced in the right-side property
/// inspector when the node is selected.
///
/// When [showRowData] is true and the node's `row` is loaded, the
/// rightmost column of each row is filled with the actual value via
/// SchemaFieldSpec.valueDisplay — that's how the card switches between
/// "schema view" and "data view" on tap. When the row hasn't loaded yet
/// (or [showRowData] is false), the right column shows the static type
/// label, matching the Schema viewer's card.
SchemaNodeData _toSchemaNode(
  LinkedRowNode node,
  List<ForeignKey> allFks, {
  required bool showRowData,
}) {
  final fkByColumn = <String, ForeignKey>{};
  for (final fk in allFks) {
    if (fk.fromSchema != node.schema || fk.fromTable != node.table) continue;
    fkByColumn.putIfAbsent(fk.fromColumn, () => fk);
  }
  final inboundRefTargets = <String>{};
  for (final fk in allFks) {
    if (fk.toSchema != node.schema || fk.toTable != node.table) continue;
    inboundRefTargets.add(fk.toColumn);
  }
  final pkSet = node.pkColumns.toSet();

  // If columns haven't loaded yet, fall back to a minimal field list
  // built from pkColumns + outbound FK columns so the card still
  // renders something sensible.
  final cols = node.columns.isNotEmpty
      ? node.columns.map((c) => (name: c.name, type: c.typeName)).toList()
      : [
          for (final c in node.bodyColumnOrder(allFks)) (name: c, type: ''),
        ];

  final fields = <SchemaFieldSpec>[];
  for (final c in cols) {
    final fk = fkByColumn[c.name];
    String? valueDisplay;
    var valueIsNull = false;
    if (showRowData) {
      final v = node.row?[c.name];
      if (v == null) {
        valueDisplay = 'NULL';
        valueIsNull = true;
      } else {
        final s = v.toString();
        valueDisplay = s.length > 32 ? '${s.substring(0, 32)}…' : s;
      }
    }
    fields.add(
      SchemaFieldSpec(
        name: c.name,
        typeLabel: c.type,
        pk: pkSet.contains(c.name),
        fk: fk != null,
        isRefTarget: inboundRefTargets.contains(c.name),
        linkedTable: fk?.toTable,
        valueDisplay: valueDisplay,
        valueIsNull: valueIsNull,
      ),
    );
  }

  return SchemaNodeData(
    id: node.id,
    schema: node.schema,
    tableName: node.table,
    fields: fields,
    subtitle: _nodeSubtitle(node),
    headerLeadingIcon: node.isSeed ? Icons.flag : null,
    position: node.position,
    compact: true,
    widthOverridden: true,
    widthOverride: node.width,
  );
}

class _NodeShell extends StatefulWidget {
  final LinkedRowNode node;
  final LinkedTab tab;
  final bool isSelected;
  final VoidCallback onDragStart;
  final void Function(DragUpdateDetails d) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;
  final VoidCallback onMount;
  final void Function(Offset globalPos)? onSecondaryTapDown;

  /// Drill-in action the SchemaCard's header "open" button fires.
  /// In the Linked view this is the explorer-style action — open the
  /// underlying row in a dedicated Table tab. null hides the button.
  final VoidCallback? onActivate;

  /// Drag delta on the right-edge resize handle, expressed in canvas
  /// (unscaled) pixels.
  final void Function(double deltaCanvas) onResizeUpdate;
  final VoidCallback onResizeEnd;
  const _NodeShell({
    required this.node,
    required this.tab,
    required this.isSelected,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
    required this.onMount,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    this.onActivate,
    this.onSecondaryTapDown,
  });

  @override
  State<_NodeShell> createState() => _NodeShellState();
}

class _NodeShellState extends State<_NodeShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onMount();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Live-data mode kicks in once the row has loaded; until then we
    // keep schema labels so the card doesn't blink between two states
    // while the row request is in flight.
    final hasRow = widget.node.row != null;
    final schemaNode = _toSchemaNode(
      widget.node,
      widget.tab.foreignKeys,
      // Always show row data once it's loaded — the user's request was
      // "show the actual data when tapping on a card", which is what
      // brings the user to the linked view at all. Always-on data also
      // matches a row card's purpose (one row, not a schema preview).
      showRowData: hasRow,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        SchemaCard(
          node: schemaNode,
          isSelected: widget.isSelected,
          isHighlighted: widget.isSelected,
          hasSelection: false,
          onTap: widget.onTap,
          onHeaderPanStart: widget.onDragStart,
          onHeaderPanUpdate: widget.onDragUpdate,
          onHeaderPanEnd: widget.onDragEnd,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          onActivate: widget.onActivate,
          activateTooltip: 'Open in Table tab',
        ),
        // Right-edge resize handle. Sits on top of the card border so
        // the user can grab and drag without clicking on a row.
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _kResizeHandleWidth,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => widget.onResizeUpdate(d.delta.dx),
              onPanEnd: (_) => widget.onResizeEnd(),
              onPanCancel: widget.onResizeEnd,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}

part of '../linked_view.dart';

/// Longest value shown in a row label or seed subtitle before it is cut
/// off with an ellipsis.
const _kMaxShortValueLength = 24;

String _short(Object? value) {
  if (value == null) return 'NULL';
  final text = value.toString();
  if (text.length <= _kMaxShortValueLength) return text;
  return '${text.substring(0, _kMaxShortValueLength)}…';
}

/// Compact "col1=val1, col2=val2" label used by the row picker panel
/// when previewing a row in the seed picker. Kept on the linked-view
/// library so it lives alongside the rest of the row-display helpers.
String _rowLabel(List<Object?> rowValues, List<GridColumnSpec> columns) {
  if (columns.isEmpty) return '(row)';
  return [
    for (var i = 0; i < columns.length; i++)
      '${columns[i].name}=${_short(i < rowValues.length ? rowValues[i] : null)}',
  ].join(', ');
}

/// Subtitle the SchemaCard renders under the table name: the metadata row
/// label once the row has loaded, else `(pk_col=val, …)` for a seed, else
/// null so the card stays compact. The ONE place this is decided — node
/// height, edge anchors and auto-width all ask it, so the card never
/// renders taller than the box the canvas gives it.
String? _nodeSubtitle(LinkedRowNode node) {
  final rowLabel = node.rowLabel;
  if (rowLabel != null) return rowLabel;
  if (!node.isSeed) return null;
  if (node.pkColumns.isEmpty) return null;
  final parts = <String>[];
  for (var i = 0; i < node.pkColumns.length; i++) {
    final value = i < node.pkValues.length ? node.pkValues[i] : null;
    parts.add('${node.pkColumns[i]}=${_short(value)}');
  }
  return '(${parts.join(', ')})';
}

/// Columns shown in the node body in compact mode — mirrors the filter
/// SchemaCard applies when `compact: true`, so the node-height and
/// edge-anchor math match what's actually rendered.
List<String> _compactColumnsFor(
  LinkedRowNode node,
  List<ForeignKey> allForeignKeys,
) {
  if (node.columns.isEmpty) {
    return node.bodyColumnOrder(allForeignKeys);
  }
  final pkSet = node.pkColumns.toSet();
  final foreignKeyColumns = <String>{
    for (final foreignKey in allForeignKeys)
      if (foreignKey.fromSchema == node.schema &&
          foreignKey.fromTable == node.table)
        foreignKey.fromColumn,
  };
  final refTargets = <String>{
    for (final foreignKey in allForeignKeys)
      if (foreignKey.toSchema == node.schema &&
          foreignKey.toTable == node.table)
        foreignKey.toColumn,
  };
  return [
    for (final column in node.columns)
      if (pkSet.contains(column.name) ||
          foreignKeyColumns.contains(column.name) ||
          refTargets.contains(column.name))
        column.name,
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
  List<ForeignKey> allForeignKeys, {
  required bool showRowData,
}) {
  final fkByColumn = <String, ForeignKey>{};
  for (final foreignKey in allForeignKeys) {
    if (foreignKey.fromSchema != node.schema ||
        foreignKey.fromTable != node.table) {
      continue;
    }
    fkByColumn.putIfAbsent(foreignKey.fromColumn, () => foreignKey);
  }
  final inboundRefTargets = <String>{};
  for (final foreignKey in allForeignKeys) {
    if (foreignKey.toSchema != node.schema ||
        foreignKey.toTable != node.table) {
      continue;
    }
    inboundRefTargets.add(foreignKey.toColumn);
  }
  final pkSet = node.pkColumns.toSet();

  // If columns haven't loaded yet, fall back to a minimal field list
  // built from pkColumns + outbound FK columns so the card still
  // renders something sensible.
  final columns = node.columns.isNotEmpty
      ? node.columns.map((c) => (name: c.name, type: c.typeName)).toList()
      : [
          for (final c in node.bodyColumnOrder(allForeignKeys))
            (name: c, type: ''),
        ];

  final fields = <SchemaFieldSpec>[];
  for (final column in columns) {
    final foreignKey = fkByColumn[column.name];
    String? valueDisplay;
    var valueIsNull = false;
    if (showRowData) {
      final value = node.row?[column.name];
      if (value == null) {
        valueDisplay = 'NULL';
        valueIsNull = true;
      } else {
        final text = value.toString();
        valueDisplay = text.length > _kMaxValueDisplayLength
            ? '${text.substring(0, _kMaxValueDisplayLength)}…'
            : text;
      }
    }
    fields.add(
      SchemaFieldSpec(
        name: column.name,
        typeLabel: column.type,
        pk: pkSet.contains(column.name),
        fk: foreignKey != null,
        isRefTarget: inboundRefTargets.contains(column.name),
        linkedTable: foreignKey?.toTable,
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
    widthOverridden: true,
    widthOverride: node.width,
  );
}

class _NodeShell extends StatefulWidget {
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
  final LinkedRowNode node;
  final LinkedTab tab;
  final bool isSelected;
  final VoidCallback onDragStart;
  final void Function(DragUpdateDetails details) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;
  final VoidCallback onMount;
  final void Function(Offset globalPosition)? onSecondaryTapDown;

  /// Drill-in action the SchemaCard's header "open" button fires.
  /// In the Linked view this is the explorer-style action — open the
  /// underlying row in a dedicated Table tab. null hides the button.
  final VoidCallback? onActivate;

  /// Drag delta on the right-edge resize handle, expressed in canvas
  /// (unscaled) pixels.
  final void Function(double deltaCanvas) onResizeUpdate;
  final VoidCallback onResizeEnd;

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
          top: 0.0,
          bottom: 0.0,
          right: 0.0,
          width: _kResizeHandleWidth,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) => widget.onResizeUpdate(details.delta.dx),
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

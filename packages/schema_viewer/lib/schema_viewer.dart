/// Backend-agnostic ER-diagram widget. The host app converts its own
/// catalog data into [SchemaNodeData] + [SchemaEdgeData], hands them
/// to [SchemaCanvas], and wires up activation / selection callbacks.
///
/// Used by dbscope for:
/// * The standalone Schema viewer tab (full diagram).
/// * The Linked view's row cards (partial diagram of the FK chain
/// the user is exploring, with live row values in each card).
library;

export 'src/gradient_edge_painter.dart' show SchemaEdgePainter;
export 'src/schema_canvas.dart'
    show SchemaCanvas, SchemaCanvasCardCallbacks, SchemaCanvasController;
export 'src/schema_card.dart' show SchemaCard;
export 'src/schema_layout.dart'
    show
        SchemaLayoutMode,
        cascadeSeparate,
        columnLocalCentreY,
        effectiveNodeWidth,
        kSchemaEmptyBodyHeight,
        kSchemaHeaderHeight,
        kSchemaNodeMargin,
        kSchemaNodeMaxWidth,
        kSchemaNodeMinWidth,
        kSchemaNodeWidth,
        kSchemaRowHeight,
        kSchemaSubtitleHeight,
        layoutSchemaNodes,
        pickEdgeSides,
        rectForNode,
        renderedNodeHeight,
        schemaNodeHeight,
        visibleFieldCountFor;
export 'src/schema_model.dart'
    show SchemaEdgeData, SchemaFieldSpec, SchemaNodeData;
export 'src/table_colors.dart'
    show
        buildTableColorMap,
        colorForTable,
        colorIndexForTable,
        kRelationshipPalette;
export 'src/type_colors.dart'
    show SchemaTypeFamily, classifyTypeName, colorForType;

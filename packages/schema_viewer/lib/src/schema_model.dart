import 'package:flutter/widgets.dart';

/// One field row on a schema card. Mirrors admin_site's FieldNodeData:
/// PK, FK, and isRefTarget control the badge/colour treatment; in compact
/// mode we filter to the union of those three.
class SchemaFieldSpec {
  final String name;
  final String typeLabel;
  final bool pk;
  final bool fk;

  /// True when at least one foreign key points at this column. Even
  /// non-PK columns can be referenced (UNIQUE), and they still need a
  /// rendering slot so inbound edges anchor onto the right row.
  final bool isRefTarget;

  /// Bare table name on the other end of an outbound FK, used to tint
  /// the row text the same colour as the destination card's header so
  /// the visual chain row → edge → header reads as one colour.
  final String? linkedTable;

  /// Display value for cells in "live" mode — null when this card is
  /// being used for schema-only rendering. When non-null, it is rendered
  /// to the right of the column name instead of the static type label.
  final String? valueDisplay;

  /// True when [valueDisplay] is logically NULL (renders muted).
  final bool valueIsNull;

  const SchemaFieldSpec({
    required this.name,
    required this.typeLabel,
    this.pk = false,
    this.fk = false,
    this.isRefTarget = false,
    this.linkedTable,
    this.valueDisplay,
    this.valueIsNull = false,
  });

  SchemaFieldSpec copyWith({
    String? valueDisplay,
    bool? valueIsNull,
  }) {
    return SchemaFieldSpec(
      name: name,
      typeLabel: typeLabel,
      pk: pk,
      fk: fk,
      isRefTarget: isRefTarget,
      linkedTable: linkedTable,
      valueDisplay: valueDisplay ?? this.valueDisplay,
      valueIsNull: valueIsNull ?? this.valueIsNull,
    );
  }
}

/// One card on the schema canvas. `id` is the schema-qualified name
/// (`schema.table`), used as the React-Flow-equivalent stable id and
/// matched against edges. `position` is canvas-space top-left.
class SchemaNodeData {
  final String id;
  final String schema;
  final String tableName;
  final List<SchemaFieldSpec> fields;

  /// Subtitle line shown under the header — used by the Linked view to
  /// display the row's PK identity. Null hides the subtitle.
  final String? subtitle;

  /// Optional flag icon (the Linked view's seed-row badge).
  final IconData? headerLeadingIcon;

  Offset position;
  bool compact;

  /// User has manually resized this card, so the auto-fit pass leaves
  /// it alone after first paint.
  bool widthOverridden;

  /// Override width when [widthOverridden] is true.
  double? widthOverride;

  SchemaNodeData({
    required this.id,
    required this.schema,
    required this.tableName,
    required this.fields,
    this.subtitle,
    this.headerLeadingIcon,
    Offset? position,
    this.compact = true,
    this.widthOverridden = false,
    this.widthOverride,
  }) : position = position ?? Offset.zero;
}

/// Directed FK edge between two schema nodes. Source is the FK side
/// (the table that owns the foreign key); target is the referenced
/// (PK) side.
class SchemaEdgeData {
  final String id;
  final String sourceId;
  final String targetId;

  /// Source-side column (the FK column). Used by the painter to anchor
  /// the start of the bezier to that row's centre when both endpoints
  /// resolve to columns the card actually exposes.
  final String? sourceField;

  /// Target-side column (the referenced PK/unique column).
  final String? targetField;

  const SchemaEdgeData({
    required this.id,
    required this.sourceId,
    required this.targetId,
    this.sourceField,
    this.targetField,
  });
}

import '../catalog/pg_type.dart';

class EditPolicy {
  final String schema;
  final String table;
  final List<String> pkColumns;
  final String column;
  final PgType type;
  final String typeName;
  final bool nullable;
  final bool isGenerated;
  final bool isIdentity;
  final bool readOnly;
  final bool multiLine;
  final bool nullIfBlank;
  final List<String>? enumValues;

  /// Why the column is read-only, when schema metadata or access control
  /// made it so (shown to the user instead of a silent no-op).
  final String? readOnlyReason;

  /// Validation hints from a metadata `policy` row.
  final String? pattern;
  final num? min;
  final num? max;

  /// Columns stamped with the current time on every edit of this row
  /// (metadata `policy.touch`, e.g. `updated_at`).
  final List<String> touchColumns;

  const EditPolicy({
    required this.schema,
    required this.table,
    required this.pkColumns,
    required this.column,
    required this.type,
    required this.typeName,
    required this.nullable,
    required this.isGenerated,
    required this.isIdentity,
    required this.readOnly,
    required this.multiLine,
    required this.nullIfBlank,
    this.enumValues,
    this.readOnlyReason,
    this.pattern,
    this.min,
    this.max,
    this.touchColumns = const [],
  });

  /// Null when [raw] passes the metadata validation hints, else a message.
  String? validate(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString();
    if (text.isEmpty) return null;
    final regex = pattern;
    if (regex != null) {
      try {
        if (!RegExp(regex).hasMatch(text)) {
          return '"$column" must match $regex.';
        }
      } on FormatException {
        // A malformed pattern in metadata must not block editing.
      }
    }
    final number = num.tryParse(text);
    if (number != null) {
      if (min != null && number < min!) return '"$column" must be ≥ $min.';
      if (max != null && number > max!) return '"$column" must be ≤ $max.';
    }
    return null;
  }

  bool get hasPk => pkColumns.isNotEmpty;
}

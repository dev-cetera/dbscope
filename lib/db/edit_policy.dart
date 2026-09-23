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
  });

  bool get hasPk => pkColumns.isNotEmpty;
}

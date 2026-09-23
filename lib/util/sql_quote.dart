String quoteIdent(String name) => '"${name.replaceAll('"', '""')}"';

String quoteQualified(String schema, String name) =>
    '${quoteIdent(schema)}.${quoteIdent(name)}';

/// Render [value] as a self-contained PostgreSQL literal. Used when we
/// need to embed a known value (e.g. a PK fetched from the same database)
/// directly into the SQL text the user will see — typically because the
/// runner does not accept positional params at that call site.
///
/// Single quotes are doubled. Numbers / bools / null are rendered without
/// quotes. Everything else falls back to a quoted string of the value's
/// `toString()`, which is what the postgres driver does for unknown types
/// internally.
String quoteLiteral(Object? value) {
  if (value == null) return 'NULL';
  if (value is bool) return value ? 'TRUE' : 'FALSE';
  if (value is num) return value.toString();
  if (value is BigInt) return value.toString();
  final s = value.toString();
  return "'${s.replaceAll("'", "''")}'";
}

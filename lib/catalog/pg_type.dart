enum PgType {
  text,
  varchar,
  name,
  int2,
  int4,
  int8,
  numeric,
  real,
  doublePrecision,
  bool_,
  date,
  time,
  timestamp,
  timestamptz,
  interval,
  uuid,
  json,
  jsonb,
  bytea,
  array,
  unknown,
}

PgType pgTypeFromUdt(String udt) {
  if (udt.startsWith('_')) return PgType.array;
  switch (udt) {
    case 'text':
      return PgType.text;
    case 'varchar':
    case 'bpchar':
    case 'char':
      return PgType.varchar;
    case 'name':
      return PgType.name;
    case 'int2':
      return PgType.int2;
    case 'int4':
      return PgType.int4;
    case 'int8':
      return PgType.int8;
    case 'numeric':
      return PgType.numeric;
    case 'float4':
      return PgType.real;
    case 'float8':
      return PgType.doublePrecision;
    case 'bool':
      return PgType.bool_;
    case 'date':
      return PgType.date;
    case 'time':
    case 'timetz':
      return PgType.time;
    case 'timestamp':
      return PgType.timestamp;
    case 'timestamptz':
      return PgType.timestamptz;
    case 'interval':
      return PgType.interval;
    case 'uuid':
      return PgType.uuid;
    case 'json':
      return PgType.json;
    case 'jsonb':
      return PgType.jsonb;
    case 'bytea':
      return PgType.bytea;
    default:
      return pgTypeFromSqlite(udt);
  }
}

/// Map a SQLite declared column type (case-insensitive, raw string from
/// PRAGMA table_info) onto the closest PgType so the grid's typed-cell
/// painter and `parseValue` keep working. SQLite is dynamically typed —
/// declared types are hints (the "type affinity" rules apply at runtime),
/// so this is a best-effort mapping.
PgType pgTypeFromSqlite(String declared) {
  final normalized = declared.trim().toUpperCase();
  if (normalized.isEmpty) return PgType.unknown;
  // Strip parameterised forms like VARCHAR(255), NUMERIC(10,2).
  final base = normalized.split('(').first.trim();
  if (base.contains('INT')) return PgType.int8;
  if (base == 'BOOL' || base == 'BOOLEAN') return PgType.bool_;
  if (base.contains('CHAR') || base.contains('CLOB') || base.contains('TEXT')) {
    return PgType.text;
  }
  if (base == 'BLOB') return PgType.bytea;
  if (base == 'REAL' ||
      base == 'FLOAT' ||
      base == 'DOUBLE' ||
      base == 'DOUBLE PRECISION') {
    return PgType.doublePrecision;
  }
  if (base.contains('NUMERIC') || base.contains('DECIMAL')) {
    return PgType.numeric;
  }
  if (base == 'DATE') return PgType.date;
  if (base == 'DATETIME' || base == 'TIMESTAMP') return PgType.timestamp;
  if (base == 'TIME') return PgType.time;
  if (base == 'JSON') return PgType.json;
  if (base == 'UUID') return PgType.uuid;
  return PgType.unknown;
}

/// Fuzzy match: pick a [PgType] from a free-form type-name fragment
/// (Postgres `format_type` output, runtime column-type strings,
/// substring matches like "character varying"). Used by query runners
/// where the wire-level UDT isn't directly available — for canonical
/// UDT names use [pgTypeFromUdt] instead.
PgType pgTypeFromTypeName(String? typeName) {
  if (typeName == null) return PgType.unknown;
  final lowerName = typeName.toLowerCase();
  if (lowerName.contains('bigint') || lowerName.contains('int8')) {
    return PgType.int8;
  }
  if (lowerName.contains('smallint') || lowerName.contains('int2')) {
    return PgType.int2;
  }
  if (lowerName.contains('integer') || lowerName.contains('int4')) {
    return PgType.int4;
  }
  if (lowerName.contains('numeric')) return PgType.numeric;
  if (lowerName.contains('real') || lowerName.contains('float4')) {
    return PgType.real;
  }
  if (lowerName.contains('double') || lowerName.contains('float8')) {
    return PgType.doublePrecision;
  }
  if (lowerName.contains('bool')) return PgType.bool_;
  if (lowerName.contains('uuid')) return PgType.uuid;
  if (lowerName.contains('timestamp') && lowerName.contains('tz')) {
    return PgType.timestamptz;
  }
  if (lowerName.contains('timestamp')) return PgType.timestamp;
  if (lowerName.contains('date')) return PgType.date;
  if (lowerName.contains('time')) return PgType.time;
  if (lowerName.contains('jsonb')) return PgType.jsonb;
  if (lowerName.contains('json')) return PgType.json;
  if (lowerName.contains('bytea')) return PgType.bytea;
  if (lowerName.contains('text')) return PgType.text;
  if (lowerName.contains('varchar') ||
      lowerName.contains('character varying')) {
    return PgType.varchar;
  }
  return PgType.unknown;
}

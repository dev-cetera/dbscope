// Translates DBScope's Postgres-style placeholders into SQLite's indexed
// placeholders. DBScope emits SQL with `$1, $2, ...` (positional) or
// `@name` (named); both shapes are quote- and comment-aware.
//
// SQLite supports `?N` for indexed positional and `:name` for named, so:
// - `$N` -> `?N` (index preserved)
// - `@name` -> `:name`
//
// A Postgres type on a placeholder (the driver's `@name:int8` annotation, or
// a `$1::int8` / `@name::int8` cast) is not SQLite syntax. It becomes
// `CAST(<param> AS <affinity>)` for types with a clear SQLite affinity
// (integers, floats, numeric, text) and is dropped for everything else
// (SQLite is dynamically typed, so `uuid`, `timestamptz`, … mean nothing).
//
// Inside string literals, identifiers, line/block comments, dollar-quoted
// strings, etc. nothing is rewritten.

class _DollarTag {
  _DollarTag(this.full);
  final String full;
}

/// Translate Postgres-style `$N` placeholders to SQLite `?N`.
String translatePositionalToSqlite(String sql) {
  final out = StringBuffer();
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];

    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        out.write(sql[i]);
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      out.write('/*');
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        out.write(sql[i]);
        i++;
      }
      if (i + 1 < sql.length) {
        out.write('*/');
        i += 2;
      }
      continue;
    }
    if (ch == "'") {
      out.write(ch);
      i++;
      while (i < sql.length) {
        if (sql[i] == "'" && i + 1 < sql.length && sql[i + 1] == "'") {
          out.write("''");
          i += 2;
          continue;
        }
        out.write(sql[i]);
        if (sql[i] == "'") {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch == '"') {
      out.write(ch);
      i++;
      while (i < sql.length) {
        if (sql[i] == '"' && i + 1 < sql.length && sql[i + 1] == '"') {
          out.write('""');
          i += 2;
          continue;
        }
        out.write(sql[i]);
        if (sql[i] == '"') {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    final dq = _readDollarTag(sql, i);
    if (dq != null) {
      out.write(dq.full);
      i += dq.full.length;
      while (i < sql.length) {
        if (sql[i] == r'$') {
          final maybe = _readDollarTag(sql, i);
          if (maybe != null && maybe.full == dq.full) {
            out.write(maybe.full);
            i += maybe.full.length;
            break;
          }
        }
        out.write(sql[i]);
        i++;
      }
      continue;
    }
    if (ch == r'$' && i + 1 < sql.length && _isDigit(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < sql.length && _isDigit(sql.codeUnitAt(j))) {
        j++;
      }
      final index = sql.substring(i + 1, j);
      final type = _readTypeSuffix(sql, j, allowAnnotation: false);
      out.write(_withAffinity('?$index', type?.name));
      i = type?.end ?? j;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// Translate Postgres-style `@name` placeholders to SQLite `:name`.
String translateNamedToSqlite(String sql) {
  final out = StringBuffer();
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        out.write(sql[i]);
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      out.write('/*');
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        out.write(sql[i]);
        i++;
      }
      if (i + 1 < sql.length) {
        out.write('*/');
        i += 2;
      }
      continue;
    }
    if (ch == "'") {
      out.write(ch);
      i++;
      while (i < sql.length) {
        if (sql[i] == "'" && i + 1 < sql.length && sql[i + 1] == "'") {
          out.write("''");
          i += 2;
          continue;
        }
        out.write(sql[i]);
        if (sql[i] == "'") {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch == '"') {
      out.write(ch);
      i++;
      while (i < sql.length) {
        if (sql[i] == '"' && i + 1 < sql.length && sql[i + 1] == '"') {
          out.write('""');
          i += 2;
          continue;
        }
        out.write(sql[i]);
        if (sql[i] == '"') {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    final dq = _readDollarTag(sql, i);
    if (dq != null) {
      out.write(dq.full);
      i += dq.full.length;
      while (i < sql.length) {
        if (sql[i] == r'$') {
          final maybe = _readDollarTag(sql, i);
          if (maybe != null && maybe.full == dq.full) {
            out.write(maybe.full);
            i += maybe.full.length;
            break;
          }
        }
        out.write(sql[i]);
        i++;
      }
      continue;
    }
    if (ch == '@' && i + 1 < sql.length && _isNameStart(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < sql.length && _isNamePart(sql.codeUnitAt(j))) {
        j++;
      }
      final name = sql.substring(i + 1, j);
      final type = _readTypeSuffix(sql, j, allowAnnotation: true);
      out.write(_withAffinity(':$name', type?.name));
      i = type?.end ?? j;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// A Postgres type written right after a placeholder at [start]: `::type`
/// (a cast) or, when [allowAnnotation], the driver's `:type` annotation.
/// Takes a dotted name, a `(precision)` and trailing `[]`s. The record's
/// `end` is the index just past it.
({String name, int end})? _readTypeSuffix(
  String sql,
  int start, {
  required bool allowAnnotation,
}) {
  var i = start;
  if (i + 1 < sql.length && sql[i] == ':' && sql[i + 1] == ':') {
    i += 2;
  } else if (allowAnnotation && i < sql.length && sql[i] == ':') {
    i += 1;
  } else {
    return null;
  }
  if (i >= sql.length || !_isNameStart(sql.codeUnitAt(i))) return null;
  final nameStart = i;
  while (i < sql.length &&
      (_isNamePart(sql.codeUnitAt(i)) || sql[i] == '.')) {
    i++;
  }
  final name = sql.substring(nameStart, i);
  if (i < sql.length && sql[i] == '(') {
    final close = sql.indexOf(')', i);
    if (close > 0) i = close + 1;
  }
  var isArray = false;
  while (i + 1 < sql.length && sql[i] == '[' && sql[i + 1] == ']') {
    isArray = true;
    i += 2;
  }
  return (name: isArray ? '$name[]' : name, end: i);
}

/// `CAST(placeholder AS affinity)` for a Postgres [type] with a clear SQLite
/// affinity, else the bare placeholder.
String _withAffinity(String placeholder, String? type) {
  if (type == null) return placeholder;
  final affinity = _sqliteAffinity[type.toLowerCase().split('.').last];
  return affinity == null ? placeholder : 'CAST($placeholder AS $affinity)';
}

const _sqliteAffinity = <String, String>{
  'int': 'INTEGER',
  'int2': 'INTEGER',
  'int4': 'INTEGER',
  'int8': 'INTEGER',
  'integer': 'INTEGER',
  'smallint': 'INTEGER',
  'bigint': 'INTEGER',
  'float4': 'REAL',
  'float8': 'REAL',
  'real': 'REAL',
  'double': 'REAL',
  'numeric': 'NUMERIC',
  'decimal': 'NUMERIC',
  'text': 'TEXT',
  'varchar': 'TEXT',
  'bpchar': 'TEXT',
  'char': 'TEXT',
  'name': 'TEXT',
};

_DollarTag? _readDollarTag(String sql, int i) {
  if (i >= sql.length || sql[i] != r'$') return null;
  var j = i + 1;
  while (j < sql.length) {
    final codeUnit = sql.codeUnitAt(j);
    if (codeUnit == 0x24) {
      return _DollarTag(sql.substring(i, j + 1));
    }
    if (!_isNamePart(codeUnit)) return null;
    j++;
  }
  return null;
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
bool _isNameStart(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
    codeUnit == 0x5f;
bool _isNamePart(int codeUnit) => _isNameStart(codeUnit) || _isDigit(codeUnit);

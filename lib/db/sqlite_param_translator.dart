// Translates DBScope's Postgres-style placeholders into SQLite's indexed
// placeholders. DBScope emits SQL with `$1, $2, ...` (positional) or
// `@name` (named); both shapes are quote- and comment-aware.
//
// SQLite supports `?N` for indexed positional and `:name` for named, so:
// - `$N` -> `?N` (index preserved)
// - `@name` -> `:name`
//
// Inside string literals, identifiers, line/block comments, dollar-quoted
// strings, etc. nothing is rewritten.

class _DollarTag {
  final String full;
  _DollarTag(this.full);
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
      final n = sql.substring(i + 1, j);
      out.write('?$n');
      i = j;
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
    if (ch == '@' &&
        i + 1 < sql.length &&
        _isNameStart(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < sql.length && _isNamePart(sql.codeUnitAt(j))) {
        j++;
      }
      final name = sql.substring(i + 1, j);
      out.write(':$name');
      i = j;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

_DollarTag? _readDollarTag(String sql, int i) {
  if (i >= sql.length || sql[i] != r'$') return null;
  var j = i + 1;
  while (j < sql.length) {
    final c = sql.codeUnitAt(j);
    if (c == 0x24) {
      return _DollarTag(sql.substring(i, j + 1));
    }
    if (!_isNamePart(c)) return null;
    j++;
  }
  return null;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
bool _isNamePart(int c) => _isNameStart(c) || _isDigit(c);

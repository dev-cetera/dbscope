// Lightweight SQL surface parsing helpers shared by the AI assistant
// and the query runner. Both need to detect "is this two statements?"
// to refuse multi-statement input. Quote-, line-comment-, and
// block-comment-aware. Not a full parser.

/// Strip leading whitespace, line comments (`--`) and block comments
/// (`/* */`) until the first real token. Inside a string literal we
/// leave content untouched.
String stripCommentsAndLeading(String sql) {
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      i++;
      continue;
    }
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        i++;
      }
      if (i + 1 < sql.length) i += 2;
      continue;
    }
    break;
  }
  return sql.substring(i);
}

/// True when [sql] contains a real second statement (i.e. a `;` followed
/// by more non-comment SQL). Single trailing `;` is OK. Doubled-quote
/// escapes (`''`) inside a string literal are honoured.
bool containsMultipleStatements(String sql) {
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == "'" || ch == '"') {
      final quote = ch;
      i++;
      while (i < sql.length) {
        if (sql[i] == quote && i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2;
          continue;
        }
        if (sql[i] == quote) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        i++;
      }
      if (i + 1 < sql.length) i += 2;
      continue;
    }
    if (ch == ';') {
      final rest = stripCommentsAndLeading(sql.substring(i + 1));
      if (rest.isNotEmpty) return true;
    }
    i++;
  }
  return false;
}

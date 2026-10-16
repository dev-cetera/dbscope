// Lightweight SQL surface parsing helpers shared by the AI assistant
// and the query runner. Both need to detect "is this two statements?"
// to refuse multi-statement input. Not a full parser: it follows the
// Postgres lexer only far enough to tell a real `;` from one hidden in
// a '' string, an E'' escape string, a $$ / $tag$ dollar-quoted body, a
// "" quoted identifier, a -- line comment or a (nested) /* */ comment.
//
// [SqlDialect.sqlite] turns off what SQLite doesn't have: E'' backslash
// escapes, dollar quoting (`$x` is a bind parameter there) and nested
// block comments. Treating them as hiding a `;` would let a real second
// statement through the check unnoticed — which is why the dialect is a
// required argument rather than defaulting to the permissive one.

/// Which SQL lexer to follow. Derive it from an executor with
/// `sqlDialectOf` (lib/meta/meta_sources.dart).
enum SqlDialect { postgres, sqlite }

const _tab = 0x09;
const _lineFeed = 0x0A;
const _carriageReturn = 0x0D;
const _space = 0x20;
const _doubleQuote = 0x22;
const _dollar = 0x24;
const _singleQuote = 0x27;
const _semicolon = 0x3B;
const _upperE = 0x45;
const _backslash = 0x5C;
const _underscore = 0x5F;
const _lowerE = 0x65;

/// Strip leading whitespace, line comments (`--`) and block comments
/// (`/* */`, nested as in Postgres) until the first real token. Stops
/// there, so string literals are never looked into.
String stripCommentsAndLeading(String sql, {required SqlDialect dialect}) {
  final nested = dialect == SqlDialect.postgres;
  var i = 0;
  while (i < sql.length) {
    if (_isSpace(sql.codeUnitAt(i))) {
      i++;
      continue;
    }
    final end = _skipComment(sql, i, nested: nested);
    if (end == i) break;
    i = end;
  }
  return sql.substring(i);
}

/// True when [sql] contains a real second statement (i.e. a `;` followed
/// by more non-comment SQL). A single trailing `;` is OK. A `;` inside a
/// string literal (`''` doubling, or `\'` in an `E'...'` string), a
/// dollar-quoted body, a quoted identifier or a comment does not count.
bool containsMultipleStatements(String sql, {required SqlDialect dialect}) {
  final postgres = dialect == SqlDialect.postgres;
  var i = 0;
  while (i < sql.length) {
    final next = _skipToken(sql, i, postgres: postgres);
    if (next > i) {
      i = next;
      continue;
    }
    if (sql.codeUnitAt(i) == _semicolon &&
        stripCommentsAndLeading(
          sql.substring(i + 1),
          dialect: dialect,
        ).isNotEmpty) {
      return true;
    }
    i++;
  }
  return false;
}

/// Index just past the comment, string literal, quoted identifier,
/// dollar-quoted body or bare identifier starting at [i], or [i] when
/// none starts there. Bare identifiers are consumed whole so a `$` or an
/// `E` inside one (`a$$b`, `typE'x'`) never opens a quote, matching the
/// Postgres lexer.
int _skipToken(String sql, int i, {required bool postgres}) {
  final afterComment = _skipComment(sql, i, nested: postgres);
  if (afterComment > i) return afterComment;
  final ch = sql.codeUnitAt(i);
  if (ch == _singleQuote) return _skipQuoted(sql, i + 1, _singleQuote);
  if (ch == _doubleQuote) return _skipQuoted(sql, i + 1, _doubleQuote);
  if (postgres && ch == _dollar) return _skipDollarQuoted(sql, i);
  if (postgres &&
      (ch == _upperE || ch == _lowerE) &&
      i + 1 < sql.length &&
      sql.codeUnitAt(i + 1) == _singleQuote) {
    return _skipQuoted(sql, i + 2, _singleQuote, escapeString: true);
  }
  if (!_isIdentStart(ch)) return i;
  var j = i + 1;
  while (j < sql.length && _isIdentPart(sql.codeUnitAt(j))) {
    j++;
  }
  return j;
}

/// Index just past the comment starting at [i], or [i] when none starts
/// there. A line comment ends before the newline (`\n` or `\r`); block
/// comments nest when [nested] (Postgres), and end at the first `*/`
/// otherwise (SQLite). Unterminated comments run to the end of [sql].
int _skipComment(String sql, int i, {required bool nested}) {
  if (sql.startsWith('--', i)) {
    var j = i + 2;
    while (j < sql.length &&
        sql.codeUnitAt(j) != _lineFeed &&
        sql.codeUnitAt(j) != _carriageReturn) {
      j++;
    }
    return j;
  }
  if (!sql.startsWith('/*', i)) return i;
  var depth = 1;
  var j = i + 2;
  while (j < sql.length && depth > 0) {
    if (nested && sql.startsWith('/*', j)) {
      depth++;
      j += 2;
    } else if (sql.startsWith('*/', j)) {
      depth--;
      j += 2;
    } else {
      j++;
    }
  }
  return j;
}

/// Index just past the [quote] closing the literal whose body starts at
/// [start]. A doubled [quote] is an escaped one. With [escapeString] (an
/// `E'...'` string) a backslash escapes the next character too, and the
/// string carries on across an SQL-standard continuation, which keeps
/// the escape mode. Unterminated literals run to the end of [sql].
int _skipQuoted(
  String sql,
  int start,
  int quote, {
  bool escapeString = false,
}) {
  var i = start;
  while (i < sql.length) {
    final ch = sql.codeUnitAt(i);
    if (escapeString && ch == _backslash) {
      i += 2;
    } else if (ch != quote) {
      i++;
    } else if (i + 1 < sql.length && sql.codeUnitAt(i + 1) == quote) {
      i += 2;
    } else {
      final resume = escapeString ? _continuationQuote(sql, i + 1) : -1;
      if (resume < 0) return i + 1;
      i = resume + 1;
    }
  }
  return sql.length;
}

/// For a string closed just before [i]: the index of the `'` that
/// continues it (`'a'` newline `'b'`, separated only by whitespace and
/// `--` comments including at least one newline), or -1 when none does.
int _continuationQuote(String sql, int i) {
  var sawNewline = false;
  var j = i;
  while (j < sql.length) {
    final ch = sql.codeUnitAt(j);
    if (ch == _lineFeed || ch == _carriageReturn) {
      sawNewline = true;
      j++;
    } else if (_isSpace(ch)) {
      j++;
    } else if (sql.startsWith('--', j)) {
      j = _skipComment(sql, j, nested: true);
    } else {
      break;
    }
  }
  final continues =
      sawNewline && j < sql.length && sql.codeUnitAt(j) == _singleQuote;
  return continues ? j : -1;
}

/// Index just past the dollar-quoted body opened by the `$` at [i]
/// (`$$...$$` or `$tag$...$tag$`, the tag being a letter or `_` followed
/// by letters, digits or `_`), or [i] when no opening delimiter starts
/// there, as with a positional parameter like `$1`. The body closes only
/// on the exact (case-sensitive) opening delimiter; an unterminated body
/// runs to the end of [sql].
int _skipDollarQuoted(String sql, int i) {
  var j = i + 1;
  if (j < sql.length && _isIdentStart(sql.codeUnitAt(j))) {
    j++;
    while (j < sql.length && _isTagPart(sql.codeUnitAt(j))) {
      j++;
    }
  }
  if (j >= sql.length || sql.codeUnitAt(j) != _dollar) return i;
  final delimiter = sql.substring(i, j + 1);
  final close = sql.indexOf(delimiter, j + 1);
  return close < 0 ? sql.length : close + delimiter.length;
}

bool _isSpace(int ch) =>
    ch == _space || ch == _tab || ch == _lineFeed || ch == _carriageReturn;

bool _isDigit(int ch) => ch >= 0x30 && ch <= 0x39;

// Postgres treats every non-ASCII byte as an identifier character; any
// UTF-16 code unit above 0x7F is the equivalent here.
bool _isIdentStart(int ch) =>
    (ch >= 0x41 && ch <= 0x5A) ||
    (ch >= 0x61 && ch <= 0x7A) ||
    ch == _underscore ||
    ch > 0x7F;

bool _isTagPart(int ch) => _isIdentStart(ch) || _isDigit(ch);

bool _isIdentPart(int ch) => _isTagPart(ch) || ch == _dollar;

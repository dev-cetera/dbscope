// Selector — the one addressing scheme every metadata row, access grant,
// and chart/action target uses.
//
// Grammar (see plan.md "Selectors"):
//
//   *                          everything (tables, columns and named queries)
//   schema                     one schema
//   schema.table               one table, and its columns
//   schema.table.column        one column
//   query:<id>                 one named query, and its result columns
//   query:<id>.<column>        one result column of a named query
//
// Each segment is a literal (exact, case-sensitive), a double-quoted literal
// using Postgres rules ("my.schema", "a""b"), or a glob where `*` matches
// any run of characters inside that one segment (`*_internal`, `*`).
//
// Specificity decides every "which rule wins" question:
//   1. depth first — a column selector beats a table selector for a column;
//   2. then segment score — literal 2, partial glob 1, bare `*` 0.

/// What a selector addresses.
enum SelectorScope {
  /// `*` alone.
  everything,

  /// `schema`, `schema.table` or `schema.table.column`.
  relation,

  /// `query:<id>` or `query:<id>.<column>`.
  query,
}

class _Segment {
  final String text;
  final bool quoted;
  final RegExp? glob;

  _Segment(this.text, {required this.quoted})
    : glob = (!quoted && text.contains('*')) ? _globToRegExp(text) : null;

  bool get isWildcard => !quoted && text == '*';
  bool get isPartialGlob => glob != null && !isWildcard;

  int get score {
    if (isWildcard) return 0;
    if (isPartialGlob) return 1;
    return 2;
  }

  bool matches(String name) {
    if (isWildcard) return true;
    final pattern = glob;
    if (pattern != null) return pattern.hasMatch(name);
    return text == name;
  }

  static RegExp _globToRegExp(String text) {
    final body = text.split('*').map(RegExp.escape).join('.*');
    return RegExp('^$body\$');
  }
}

/// A parsed selector. Build with [Selector.tryParse]; a malformed string
/// returns null so callers can report a problem instead of throwing.
class Selector {
  final String raw;
  final SelectorScope scope;
  final List<_Segment> _segments;

  const Selector._(this.raw, this.scope, this._segments);

  static const Selector everything = Selector._(
    '*',
    SelectorScope.everything,
    [],
  );

  static const String queryPrefix = 'query:';

  /// Parses [raw]. Returns null on syntax errors (unbalanced quotes, empty
  /// segments, too many segments).
  static Selector? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed == '*') return everything;
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith(queryPrefix)) {
      final segments = _splitSegments(trimmed.substring(queryPrefix.length));
      if (segments == null || segments.isEmpty || segments.length > 2) {
        return null;
      }
      return Selector._(trimmed, SelectorScope.query, segments);
    }
    final segments = _splitSegments(trimmed);
    if (segments == null || segments.isEmpty || segments.length > 3) {
      return null;
    }
    return Selector._(trimmed, SelectorScope.relation, segments);
  }

  /// Convenience for code that builds selectors from known names (never
  /// user input): quotes every segment so dots and globs are literal.
  static Selector forColumn(String schema, String table, String column) =>
      tryParse('${quote(schema)}.${quote(table)}.${quote(column)}')!;

  static Selector forTable(String schema, String table) =>
      tryParse('${quote(schema)}.${quote(table)}')!;

  static String quote(String name) => '"${name.replaceAll('"', '""')}"';

  /// Number of segments, normalised so table-level and column-level
  /// selectors compare the same way for relations and queries:
  /// 0 = everything, 1 = schema, 2 = table / query, 3 = column.
  int get depth {
    switch (scope) {
      case SelectorScope.everything:
        return 0;
      case SelectorScope.relation:
        return _segments.length;
      case SelectorScope.query:
        return _segments.length + 1;
    }
  }

  /// Sum of segment scores (literal 2, partial glob 1, `*` 0).
  int get score {
    var total = 0;
    for (final s in _segments) {
      total += s.score;
    }
    return total;
  }

  /// One comparable number: depth dominates, score breaks ties.
  int get specificity => depth * 100 + score;

  bool get isColumnLevel => depth == 3;

  /// Does this selector apply to the table [schema].[table]? Column-level
  /// selectors never apply to a table as a whole.
  bool matchesTable(String schema, String table) {
    switch (scope) {
      case SelectorScope.everything:
        return true;
      case SelectorScope.query:
        return false;
      case SelectorScope.relation:
        if (_segments.length > 2) return false;
        if (!_segments[0].matches(schema)) return false;
        return _segments.length == 1 || _segments[1].matches(table);
    }
  }

  /// Does this selector apply to the column [schema].[table].[column]?
  /// Table- and schema-level selectors apply to every column inside.
  bool matchesColumn(String schema, String table, String column) {
    switch (scope) {
      case SelectorScope.everything:
        return true;
      case SelectorScope.query:
        return false;
      case SelectorScope.relation:
        if (!_segments[0].matches(schema)) return false;
        if (_segments.length >= 2 && !_segments[1].matches(table)) {
          return false;
        }
        return _segments.length < 3 || _segments[2].matches(column);
    }
  }

  /// For a column-level selector that names its schema and table
  /// LITERALLY (no globs): are they [schema].[table]? Glob selectors like
  /// `*.*.dev_notes` are deliberately excluded — they describe a column
  /// everywhere, not an intent to open any particular table.
  bool namesColumnOfTable(String schema, String table) =>
      scope == SelectorScope.relation &&
      _segments.length == 3 &&
      _segments[0].glob == null &&
      _segments[1].glob == null &&
      _segments[0].matches(schema) &&
      _segments[1].matches(table);

  /// Is this exactly a schema-level selector that matches [schema]?
  bool matchesSchemaOnly(String schema) =>
      scope == SelectorScope.relation &&
      _segments.length == 1 &&
      _segments[0].matches(schema);

  /// Does this selector apply to the named query [queryId] as a whole?
  bool matchesQuery(String queryId) {
    switch (scope) {
      case SelectorScope.everything:
        return true;
      case SelectorScope.relation:
        return false;
      case SelectorScope.query:
        return _segments.length == 1 && _segments[0].matches(queryId);
    }
  }

  /// Does this selector apply to result column [column] of [queryId]?
  bool matchesQueryColumn(String queryId, String column) {
    switch (scope) {
      case SelectorScope.everything:
        return true;
      case SelectorScope.relation:
        return false;
      case SelectorScope.query:
        if (!_segments[0].matches(queryId)) return false;
        return _segments.length < 2 || _segments[1].matches(column);
    }
  }

  /// The literal table this selector names, when it names exactly one
  /// table (no globs). Used by features that need a concrete target, such
  /// as a chart's source or an action's table.
  ({String schema, String table})? get exactTable {
    if (scope != SelectorScope.relation || _segments.length != 2) return null;
    if (_segments.any((s) => s.glob != null)) return null;
    return (schema: _segments[0].text, table: _segments[1].text);
  }

  /// The literal column this selector names, when it names exactly one.
  ({String schema, String table, String column})? get exactColumn {
    if (scope != SelectorScope.relation || _segments.length != 3) return null;
    if (_segments.any((s) => s.glob != null)) return null;
    return (
      schema: _segments[0].text,
      table: _segments[1].text,
      column: _segments[2].text,
    );
  }

  /// The literal query id, when this is `query:<id>` or `query:<id>.<col>`.
  String? get exactQueryId {
    if (scope != SelectorScope.query) return null;
    if (_segments[0].glob != null) return null;
    return _segments[0].text;
  }

  /// The literal column segment, when the last segment is a literal and the
  /// selector is column-level (relation or query).
  String? get exactColumnName {
    final isColumn =
        (scope == SelectorScope.relation && _segments.length == 3) ||
        (scope == SelectorScope.query && _segments.length == 2);
    if (!isColumn) return null;
    final last = _segments.last;
    return last.glob == null ? last.text : null;
  }

  @override
  String toString() => raw;

  @override
  bool operator ==(Object other) => other is Selector && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  /// Splits on dots outside double quotes. Returns null on unbalanced
  /// quotes or an empty segment.
  static List<_Segment>? _splitSegments(String text) {
    final out = <_Segment>[];
    final current = StringBuffer();
    var inQuotes = false;
    var segmentWasQuoted = false;
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            current.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        current.write(ch);
        i++;
        continue;
      }
      if (ch == '"') {
        if (current.isNotEmpty) return null; // quote mid-segment
        inQuotes = true;
        segmentWasQuoted = true;
        i++;
        continue;
      }
      if (ch == '.') {
        if (current.isEmpty && !segmentWasQuoted) return null;
        out.add(_Segment(current.toString(), quoted: segmentWasQuoted));
        current.clear();
        segmentWasQuoted = false;
        i++;
        continue;
      }
      if (segmentWasQuoted) return null; // text after a closing quote
      current.write(ch);
      i++;
    }
    if (inQuotes) return null;
    if (current.isEmpty && !segmentWasQuoted) return null;
    out.add(_Segment(current.toString(), quoted: segmentWasQuoted));
    return out;
  }
}

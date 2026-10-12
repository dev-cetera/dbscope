// Binding metadata SQL to a context: actions, row-scoped charts, named
// queries with inputs.
//
// Placeholders use the Postgres driver's own named-parameter syntax
// (`@name`, letters/digits/underscore; see postgres 3.5's VariableTokenizer),
// which `PostgresExecutor` already runs through `pg.Sql.named`, and which
// `sqlite_param_translator.dart` already rewrites to SQLite's `:name`.
// So binding only has to (a) find which `@names` the SQL uses, (b) supply
// their values, and (c) expand selection lists into `IN (...)` lists.
// Values are always parameters — never pasted into the SQL.
//
//   @row_<col>   value of <col> in the context row
//   @pk_<col>    value of primary-key <col>
//   @cell        the clicked cell's value
//   @column @table @schema   names, bound as VALUES (never identifiers)
//   @input_<name>   a value the user typed into the action's prompt
//   @rows_<col>  a multi-row selection: expanded to @rows_<col>_0, …_n
//   @me_principal   the identity dbscope resolved (pg:… or user:…)

import 'meta_models.dart';

/// Upper bound on a selection expanded into `IN (...)`.
const kMaxSelectionBind = 1000;

class BindingContext {
  const BindingContext({
    this.schema,
    this.table,
    this.column,
    this.row = const {},
    this.primaryKey = const {},
    this.cell,
    this.selection = const [],
    this.inputs = const {},
    this.mePrincipal,
  });
  final String? schema;
  final String? table;
  final String? column;
  final Map<String, Object?> row;
  final Map<String, Object?> primaryKey;
  final Object? cell;
  final List<Map<String, Object?>> selection;
  final Map<String, Object?> inputs;
  final String? mePrincipal;
}

class BoundSql {
  const BoundSql(this.sql, this.named, this.missing);
  final String sql;
  final Map<String, Object?> named;

  /// Placeholders the context could not satisfy. Non-empty → don't run.
  final List<String> missing;

  bool get isComplete => missing.isEmpty;
}

const _rowPrefix = 'row_';
const _pkPrefix = 'pk_';
const _inputPrefix = 'input_';
const _rowsPrefix = 'rows_';

/// Every `@name` placeholder in [sql], in order of first appearance,
/// skipping string literals, quoted identifiers, comments and dollar-quoted
/// bodies (the same places the driver skips).
List<String> findPlaceholders(String sql) {
  final names = <String>[];
  _scan(sql, (name, annotation) {
    if (!names.contains(name)) names.add(name);
    return null;
  });
  return names;
}

/// Binds [sql] against [context].
BoundSql bindSql(String sql, BindingContext context) {
  final named = <String, Object?>{};
  final missing = <String>[];

  String? valueFor(String name, void Function(Object?) put) {
    if (name == 'cell') {
      put(context.cell);
      return null;
    }
    if (name == 'column') {
      if (context.column == null) return name;
      put(context.column);
      return null;
    }
    if (name == 'table') {
      if (context.table == null) return name;
      put(context.table);
      return null;
    }
    if (name == 'schema') {
      if (context.schema == null) return name;
      put(context.schema);
      return null;
    }
    if (name == 'me_principal') {
      put(context.mePrincipal);
      return null;
    }
    if (name.startsWith(_rowPrefix)) {
      final col = name.substring(_rowPrefix.length);
      if (!context.row.containsKey(col)) return name;
      put(context.row[col]);
      return null;
    }
    if (name.startsWith(_pkPrefix)) {
      final col = name.substring(_pkPrefix.length);
      if (!context.primaryKey.containsKey(col)) return name;
      put(context.primaryKey[col]);
      return null;
    }
    if (name.startsWith(_inputPrefix)) {
      final input = name.substring(_inputPrefix.length);
      if (!context.inputs.containsKey(input)) return name;
      put(context.inputs[input]);
      return null;
    }
    return name;
  }

  final rewritten = _scan(sql, (name, annotation) {
    if (name.startsWith(_rowsPrefix)) {
      final col = name.substring(_rowsPrefix.length);
      // Never silently act on part of a selection: too many rows, or rows
      // without the column, make the placeholder unsatisfiable.
      final selection = context.selection;
      final complete =
          selection.isNotEmpty &&
          selection.length <= kMaxSelectionBind &&
          selection.every((row) => row.containsKey(col));
      if (!complete) {
        final reason = selection.length > kMaxSelectionBind
            ? '$name (more than $kMaxSelectionBind rows selected)'
            : name;
        if (!missing.contains(reason)) missing.add(reason);
        return null;
      }
      final parts = <String>[];
      for (var i = 0; i < selection.length; i++) {
        final key = '${name}_$i';
        named[key] = selection[i][col];
        parts.add(annotation == null ? '@$key' : '@$key:$annotation');
      }
      return parts.join(', ');
    }
    final unresolved = valueFor(name, (v) => named[name] = v);
    if (unresolved != null && !missing.contains(unresolved)) {
      missing.add(unresolved);
    }
    return null;
  });
  return BoundSql(rewritten, named, missing);
}

/// [bound] rewritten from `@name` to `$n` positional placeholders, numbered
/// from [startAt] — the shape `KeysetPager.baseWhere` takes. A driver type
/// annotation (`@x:int8`) becomes a cast (`$1::int8`).
({String sql, List<Object?> params}) toPositional(
  BoundSql bound, {
  int startAt = 1,
}) {
  final params = <Object?>[];
  final indexByName = <String, int>{};
  final rewritten = _scan(bound.sql, (name, annotation) {
    final index = indexByName.putIfAbsent(name, () {
      params.add(bound.named[name]);
      return startAt + params.length - 1;
    });
    // A driver type annotation (`@x:int8`) becomes a cast (`$1::int8`).
    return annotation == null ? '\$$index' : '\$$index::$annotation';
  });
  return (sql: rewritten, params: params);
}

/// Renders a `{…}` text template (URLs, copy text, confirm prompts).
/// `{cell}`, `{row.<col>}`, `{input.<name>}`, `{table}`, `{schema}`,
/// `{column}`. [encode] is applied to every substituted value (pass
/// `Uri.encodeComponent` for URLs). Unknown placeholders render empty.
String renderTemplate(
  String template,
  BindingContext context, {
  String Function(String)? encode,
}) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_.]+)\}'), (m) {
    final key = m.group(1)!;
    Object? value;
    if (key == 'cell') {
      value = context.cell;
    } else if (key == 'table') {
      value = context.table;
    } else if (key == 'schema') {
      value = context.schema;
    } else if (key == 'column') {
      value = context.column;
    } else if (key.startsWith('row.')) {
      value = context.row[key.substring(4)];
    } else if (key.startsWith('input.')) {
      value = context.inputs[key.substring(6)];
    }
    final text = value?.toString() ?? '';
    return encode == null ? text : encode(text);
  });
}

/// Evaluates an action's `when` condition against the context row:
/// every listed `row.<col>` must hold one of its listed values.
bool whenHolds(ActionSpec action, BindingContext context) {
  for (final entry in action.when.entries) {
    final key = entry.key;
    final column = key.startsWith('row.') ? key.substring(4) : key;
    if (!context.row.containsKey(column)) return false;
    final value = context.row[column]?.toString();
    if (!entry.value.contains(value)) return false;
  }
  return true;
}

/// Placeholders an action needs from the row that the row doesn't have
/// (shown as the reason an action is disabled). Inputs are excluded — the
/// user is prompted for those.
List<String> missingRowPlaceholders(String sql, BindingContext context) {
  final out = <String>[];
  for (final name in findPlaceholders(sql)) {
    if (name.startsWith(_rowPrefix) &&
        !context.row.containsKey(name.substring(_rowPrefix.length))) {
      out.add(name);
    }
    if (name.startsWith(_pkPrefix) &&
        !context.primaryKey.containsKey(name.substring(_pkPrefix.length))) {
      out.add(name);
    }
  }
  return out;
}

// ─── Scanner ────────────────────────────────────────────────────────────

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

/// Walks [sql]; for every `@name` placeholder (with its optional driver
/// type annotation, `@name:type`) calls [onPlaceholder]. When it returns a
/// string, that string replaces the whole `@name[:type]` token.
String _scan(
  String sql,
  String? Function(String name, String? annotation) onPlaceholder,
) {
  final out = StringBuffer();
  var i = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql.codeUnitAt(i);
    // -- line comment
    if (c == 0x2d && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2d) {
      final end = sql.indexOf('\n', i);
      final stop = end < 0 ? n : end;
      out.write(sql.substring(i, stop));
      i = stop;
      continue;
    }
    // /* block comment */
    if (c == 0x2f && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2a) {
      final end = sql.indexOf('*/', i + 2);
      final stop = end < 0 ? n : end + 2;
      out.write(sql.substring(i, stop));
      i = stop;
      continue;
    }
    // E'escape string' — backslash escapes as well as ''.
    final isEscapeString =
        (c == 0x45 || c == 0x65) &&
        i + 1 < n &&
        sql.codeUnitAt(i + 1) == 0x27 &&
        (i == 0 || !_isIdentChar(sql.codeUnitAt(i - 1)));
    if (isEscapeString) {
      var j = i + 2;
      while (j < n) {
        final d = sql.codeUnitAt(j);
        if (d == 0x5c) {
          j += 2;
          continue;
        }
        if (d == 0x27) {
          if (j + 1 < n && sql.codeUnitAt(j + 1) == 0x27) {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      final stop = j < n ? j + 1 : n;
      out.write(sql.substring(i, stop));
      i = stop;
      continue;
    }
    // 'string' or "identifier" ('' / "" escapes)
    if (c == 0x27 || c == 0x22) {
      var j = i + 1;
      while (j < n) {
        if (sql.codeUnitAt(j) == c) {
          if (j + 1 < n && sql.codeUnitAt(j + 1) == c) {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      final stop = j < n ? j + 1 : n;
      out.write(sql.substring(i, stop));
      i = stop;
      continue;
    }
    // $tag$ dollar-quoted $tag$
    if (c == 0x24) {
      final match = RegExp(
        r'\$([A-Za-z_][A-Za-z0-9_]*)?\$',
      ).matchAsPrefix(sql, i);
      if (match != null) {
        final tag = match.group(0)!;
        final end = sql.indexOf(tag, i + tag.length);
        final stop = end < 0 ? n : end + tag.length;
        out.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
    }
    // @name[:type] — like the driver, regardless of what precedes the @.
    if (c == 0x40 && i + 1 < n && _isIdentStart(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < n && _isIdentChar(sql.codeUnitAt(j))) {
        j++;
      }
      final name = sql.substring(i + 1, j);
      String? annotation;
      // `@x:int8` is an annotation; `@x::int8` is a real cast.
      if (j + 1 < n &&
          sql.codeUnitAt(j) == 0x3a &&
          sql.codeUnitAt(j + 1) != 0x3a &&
          _isIdentStart(sql.codeUnitAt(j + 1))) {
        var k = j + 1;
        while (k < n && _isIdentChar(sql.codeUnitAt(k))) {
          k++;
        }
        annotation = sql.substring(j + 1, k);
        j = k;
      }
      final replacement = onPlaceholder(name, annotation);
      out.write(replacement ?? sql.substring(i, j));
      i = j;
      continue;
    }
    out.writeCharCode(c);
    i++;
  }
  return out.toString();
}

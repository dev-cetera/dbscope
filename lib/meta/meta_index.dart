// MetaIndex — answers "what does the metadata say about X?" for one
// connection. Pure: built from a MetaDocument, no I/O.
//
// Scalar kinds (describe, display, sensitive, policy, ai) merge field by
// field. Matching rows are ordered least-specific first, then by source
// precedence, then by priority, and later rows overwrite earlier fields.
// So the most specific rule wins, and on equal specificity the higher
// source (profile > file > database > native comments) wins.
//
// List kinds (link, action, query, chart, check, dashboard) are already
// de-duplicated by id in mergeMetaSources; here they are parsed once.

import 'meta_models.dart';
import 'selector.dart';

/// What a lookup is about.
sealed class MetaTarget {
  const MetaTarget();
  bool matches(Selector selector);
}

class TableTarget extends MetaTarget {
  const TableTarget(this.schema, this.table);
  final String schema;
  final String table;
  @override
  bool matches(Selector selector) => selector.matchesTable(schema, table);
}

class SchemaTarget extends MetaTarget {
  const SchemaTarget(this.schema);
  final String schema;
  @override
  bool matches(Selector selector) => selector.matchesSchemaOnly(schema);
}

class ColumnTarget extends MetaTarget {
  const ColumnTarget(this.schema, this.table, this.column);
  final String schema;
  final String table;
  final String column;
  @override
  bool matches(Selector selector) =>
      selector.matchesColumn(schema, table, column);
}

class QueryTarget extends MetaTarget {
  const QueryTarget(this.queryId);
  final String queryId;
  @override
  bool matches(Selector selector) => selector.matchesQuery(queryId);
}

class QueryColumnTarget extends MetaTarget {
  const QueryColumnTarget(this.queryId, this.column);
  final String queryId;
  final String column;
  @override
  bool matches(Selector selector) =>
      selector.matchesQueryColumn(queryId, column);
}

class MetaIndex {
  MetaIndex._({
    required this.document,
    required this.links,
    required this.actions,
    required this.queries,
    required this.charts,
    required this.checks,
    required this.dashboards,
    required this.rbac,
    required this.problems,
    required this._scalarRowsByKind,
  });

  factory MetaIndex.build(MetaDocument document) {
    final problems = <MetaProblem>[];
    final scalar = <String, List<MetaRow>>{};
    final links = <LinkSpec>[];
    final actions = <ActionSpec>[];
    final queries = <NamedQuerySpec>[];
    final charts = <ChartSpec>[];
    final checks = <CheckSpec>[];
    final dashboards = <DashboardSpec>[];

    for (final row in document.rows) {
      if (row.isScalarKind) {
        (scalar[row.kind] ??= []).add(row);
        continue;
      }
      switch (row.kind) {
        case MetaKinds.link:
          final link = LinkSpec.fromRow(row);
          if (link.to == null && !link.isPolymorphic && !link.isUrl) {
            problems.add(
              MetaProblem(
                row.source,
                row.id,
                'A link needs to, polymorphic or url.',
              ),
            );
          } else {
            links.add(link);
          }
        case MetaKinds.action:
          final action = ActionSpec.fromRow(row, problems);
          if (action != null) actions.add(action);
        case MetaKinds.query:
          final query = NamedQuerySpec.fromRow(row, problems);
          if (query != null) queries.add(query);
        case MetaKinds.chart:
          final chart = ChartSpec.fromRow(row, problems);
          if (chart != null) charts.add(chart);
        case MetaKinds.check:
          final check = CheckSpec.fromRow(row, problems);
          if (check != null) checks.add(check);
        case MetaKinds.dashboard:
          dashboards.add(DashboardSpec.fromRow(row));
      }
    }

    int order(MetaRow a, MetaRow b) {
      final bySpecificity = a.target.specificity.compareTo(
        b.target.specificity,
      );
      if (bySpecificity != 0) return bySpecificity;
      final bySource = a.source.index.compareTo(b.source.index);
      if (bySource != 0) return bySource;
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      // List.sort isn't stable: the id makes equal rules merge in a fixed,
      // documented order (later id wins).
      return a.id.compareTo(b.id);
    }

    for (final list in scalar.values) {
      list.sort(order);
    }
    queries.sort((a, b) => a.label.compareTo(b.label));
    charts.sort((a, b) => a.label.compareTo(b.label));
    checks.sort((a, b) => a.label.compareTo(b.label));

    final rbacRows = scalar[MetaKinds.rbac] ?? const <MetaRow>[];
    final rbacSpec = <String, Object?>{};
    for (final row in rbacRows) {
      rbacSpec.addAll(row.spec);
    }

    return MetaIndex._(
      document: document,
      links: links,
      actions: actions,
      queries: queries,
      charts: charts,
      checks: checks,
      dashboards: dashboards,
      rbac: RbacSettings.fromJson(rbacSpec),
      problems: problems,
      scalarRowsByKind: scalar,
    );
  }
  final MetaDocument document;
  final List<LinkSpec> links;
  final List<ActionSpec> actions;
  final List<NamedQuerySpec> queries;
  final List<ChartSpec> charts;
  final List<CheckSpec> checks;
  final List<DashboardSpec> dashboards;
  final RbacSettings rbac;

  /// Problems found while parsing list kinds (on top of the document's).
  final List<MetaProblem> problems;

  final Map<String, List<MetaRow>> _scalarRowsByKind;

  static final empty = MetaIndex.build(MetaDocument.empty);

  List<MetaProblem> get allProblems => [...document.problems, ...problems];

  /// Field-by-field merge of every [kind] row matching [target]. When
  /// [columnDepthOnly] is set, only column-level selectors count (so a
  /// table's description never becomes each column's description).
  Map<String, Object?> merged(
    String kind,
    MetaTarget target, {
    bool columnDepthOnly = false,
  }) {
    final rows = _scalarRowsByKind[kind];
    if (rows == null) return const {};
    final out = <String, Object?>{};
    for (final row in rows) {
      if (columnDepthOnly && !_isColumnSelector(row.target)) continue;
      if (!target.matches(row.target)) continue;
      out.addAll(row.spec);
    }
    return out;
  }

  static bool _isColumnSelector(Selector selector) => selector.isColumnLevel;

  // ─── Describe ─────────────────────────────────────────────────────

  DescribeSpec describeSchema(String schema) => DescribeSpec.fromJson(
    _mergedExact(MetaKinds.describe, SchemaTarget(schema), depth: 1),
  );

  DescribeSpec describeTable(String schema, String table) =>
      DescribeSpec.fromJson(
        _mergedExact(MetaKinds.describe, TableTarget(schema, table), depth: 2),
      );

  DescribeSpec describeColumn(String schema, String table, String column) =>
      DescribeSpec.fromJson(
        merged(
          MetaKinds.describe,
          ColumnTarget(schema, table, column),
          columnDepthOnly: true,
        ),
      );

  DescribeSpec describeQuery(String queryId) => DescribeSpec.fromJson(
    _mergedExact(MetaKinds.describe, QueryTarget(queryId), depth: 2),
  );

  DescribeSpec describeQueryColumn(String queryId, String column) =>
      DescribeSpec.fromJson(
        merged(
          MetaKinds.describe,
          QueryColumnTarget(queryId, column),
          columnDepthOnly: true,
        ),
      );

  /// Like [merged] but only selectors whose depth is exactly [depth] — a
  /// schema-wide `describe` must not label every table.
  Map<String, Object?> _mergedExact(
    String kind,
    MetaTarget target, {
    required int depth,
  }) {
    final rows = _scalarRowsByKind[kind];
    if (rows == null) return const {};
    final out = <String, Object?>{};
    for (final row in rows) {
      if (row.target.depth != depth) continue;
      if (!target.matches(row.target)) continue;
      out.addAll(row.spec);
    }
    return out;
  }

  // ─── Display ──────────────────────────────────────────────────────

  /// Table-level display (rowLabel, order, pinned, defaultSort, group…).
  /// Schema-wide and `*` rows apply, column rows don't.
  DisplaySpec displayTable(String schema, String table) => DisplaySpec.fromJson(
    merged(MetaKinds.display, TableTarget(schema, table)),
  );

  /// Column-level display (renderer, rendererArgs). Column selectors only.
  DisplaySpec displayColumn(String schema, String table, String column) =>
      DisplaySpec.fromJson(
        merged(
          MetaKinds.display,
          ColumnTarget(schema, table, column),
          columnDepthOnly: true,
        ),
      );

  DisplaySpec displayQuery(String queryId) =>
      DisplaySpec.fromJson(merged(MetaKinds.display, QueryTarget(queryId)));

  DisplaySpec displayQueryColumn(String queryId, String column) =>
      DisplaySpec.fromJson(
        merged(
          MetaKinds.display,
          QueryColumnTarget(queryId, column),
          columnDepthOnly: true,
        ),
      );

  /// The display group of a table, for sidebar folders. Null = ungrouped.
  String? groupOf(String schema, String table) =>
      displayTable(schema, table).group;

  // ─── Sensitive / policy / ai ──────────────────────────────────────

  /// Sensitive applies at every depth: a sensitive table makes all its
  /// columns sensitive.
  SensitiveSpec sensitiveColumn(String schema, String table, String column) =>
      SensitiveSpec.fromJson(
        merged(MetaKinds.sensitive, ColumnTarget(schema, table, column)),
      );

  SensitiveSpec sensitiveQueryColumn(String queryId, String column) =>
      SensitiveSpec.fromJson(
        merged(MetaKinds.sensitive, QueryColumnTarget(queryId, column)),
      );

  PolicySpec policyTable(String schema, String table) => PolicySpec.fromJson(
    merged(MetaKinds.policy, TableTarget(schema, table)),
  );

  PolicySpec policyColumn(String schema, String table, String column) =>
      PolicySpec.fromJson(
        merged(MetaKinds.policy, ColumnTarget(schema, table, column)),
      );

  /// Every `ai` note that applies anywhere, most general first, for the
  /// SQL assistant's prompt.
  List<({String target, AiSpec spec})> aiNotes() => [
    for (final row in _scalarRowsByKind[MetaKinds.ai] ?? const <MetaRow>[])
      (target: row.target.raw, spec: AiSpec.fromJson(row.spec)),
  ];

  // ─── Lists ────────────────────────────────────────────────────────

  NamedQuerySpec? queryById(String id) {
    for (final query in queries) {
      if (query.id == id) return query;
    }
    return null;
  }

  ChartSpec? chartById(String id) {
    for (final chart in charts) {
      if (chart.id == id) return chart;
    }
    return null;
  }

  /// Links whose target matches this column (virtual FKs, polymorphic
  /// links, JSON-path links and URL links).
  List<LinkSpec> linksForColumn(String schema, String table, String column) => [
    for (final link in links)
      if (link.target.isColumnLevel &&
          link.target.matchesColumn(schema, table, column))
        link,
  ];

  List<LinkSpec> linksForQueryColumn(String queryId, String column) => [
    for (final link in links)
      if (link.target.matchesQueryColumn(queryId, column) &&
          link.target.exactColumnName != null)
        link,
  ];

  /// Actions of [scope] that apply to a table (scope table/row/selection)
  /// or a column (scope cell).
  List<ActionSpec> actionsForTable(
    ActionScope scope,
    String schema,
    String table,
  ) => [
    for (final action in actions)
      if (action.scope == scope && action.target.matchesTable(schema, table))
        action,
  ];

  List<ActionSpec> actionsForCell(String schema, String table, String column) =>
      [
        for (final action in actions)
          if (action.scope == ActionScope.cell &&
              action.target.matchesColumn(schema, table, column))
            action,
      ];

  List<ActionSpec> actionsForQuery(ActionScope scope, String queryId) => [
    for (final action in actions)
      if (action.scope == scope && action.target.matchesQuery(queryId)) action,
  ];

  List<ActionSpec> actionsForQueryCell(String queryId, String column) => [
    for (final action in actions)
      if (action.scope == ActionScope.cell &&
          action.target.matchesQueryColumn(queryId, column))
        action,
  ];

  List<ActionSpec> get globalActions => [
    for (final action in actions)
      if (action.scope == ActionScope.global) action,
  ];

  /// Charts shown on a table's Charts strip (not row-scoped).
  List<ChartSpec> chartsForTable(String schema, String table) => [
    for (final chart in charts)
      if (!chart.rowScoped && _chartBelongsToTable(chart, schema, table)) chart,
  ];

  /// Row-scoped charts for a row of [schema].[table].
  List<ChartSpec> rowChartsForTable(String schema, String table) => [
    for (final chart in charts)
      if (chart.rowScoped && chart.target.matchesTable(schema, table)) chart,
  ];

  List<ChartSpec> chartsForQuery(String queryId) => [
    for (final chart in charts)
      if (!chart.rowScoped &&
          chart.source is ChartQuerySource &&
          (chart.source as ChartQuerySource).queryId == queryId)
        chart,
  ];

  bool _chartBelongsToTable(ChartSpec chart, String schema, String table) {
    final source = chart.source;
    if (source is ChartTableSource) {
      return source.schema == schema && source.table == table;
    }
    return chart.target.exactTable?.schema == schema &&
        chart.target.exactTable?.table == table;
  }

  List<CheckSpec> checksForTable(String schema, String table) => [
    for (final check in checks)
      if (check.target.exactTable != null &&
          check.target.matchesTable(schema, table))
        check,
  ];
}

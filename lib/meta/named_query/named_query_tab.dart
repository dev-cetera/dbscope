import '../../grid/data_grid.dart';
import '../../tabs/tab_model.dart';
import '../meta_models.dart';

/// A tab showing the result of a named query from schema metadata
/// (`kind: query`), or of a metadata action's query.
///
/// A named query is a first-class relation: its result columns take
/// descriptions, renderers, links, row actions, charts and access grants
/// (`query:<id>.<column>`), and it runs for users without the `query`
/// capability, because they can only run what the metadata defines.
class NamedQueryTab extends TabModel {
  NamedQueryTab({
    super.id,
    required super.connectionId,
    required String this.queryId,
    required this.label,
    this.autoRun = true,
  }) : sql = '',
       boundParams = const {},
       accessTable = null,
       fromMetadata = true;

  NamedQueryTab.adHoc({
    required super.connectionId,
    required this.label,
    required this.sql,
    required this.boundParams,
    this.accessTable,
    this.fromMetadata = true,
  }) : queryId = null,
       autoRun = true;

  /// The metadata query id, or null for an action's ad-hoc query.
  final String? queryId;
  final String label;

  /// SQL for ad-hoc (action) queries. Named queries re-read their SQL from
  /// the metadata on every run, so metadata edits apply.
  final String sql;

  /// Values already bound by the action (row, pk, cell…).
  final Map<String, Object?> boundParams;

  /// For action queries: the table whose column access applies to result
  /// columns by name (best effort — free SQL can rename columns).
  final ({String schema, String table})? accessTable;

  /// Values typed into the query's inputs.
  final Map<String, String> inputValues = {};

  GridData? data;
  var isLoading = false;
  String? error;
  Duration? elapsed;
  var truncated = false;
  int? selectedRowIndex;
  GridViewMode viewMode = GridViewMode.typed;
  var showSql = false;
  var chartsOpen = true;

  /// One-shot: run after the first frame.
  bool autoRun;

  /// Whether the SQL came from the metadata (and so needs the user's trust
  /// and runs read-only). False for SQL dbscope wrote itself, such as the
  /// inbound-reference lookup.
  final bool fromMetadata;

  @override
  String get title => label;

  /// Inputs to prompt for, from the metadata spec (named queries only).
  List<ActionInput> inputsFrom(NamedQuerySpec? spec) => spec?.inputs ?? const [];
}

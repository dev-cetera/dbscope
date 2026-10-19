import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../grid/data_grid.dart';
import '../meta/access_policy.dart';
import '../tabs/tab_model.dart';

/// A fixed WHERE applied to a table tab by a metadata `openTable` action
/// (e.g. "Find account by email…"). Positional `$n` placeholders numbered
/// from 1, values in [params]. Transient: not persisted with the tab.
class MetaTableFilter {
  const MetaTableFilter({
    required this.label,
    required this.where,
    required this.params,
  });
  final String label;
  final String where;
  final List<Object?> params;
}

/// Sort state for a [TableTab]. Persisted with the tab so a refresh
/// keeps the user's chosen sort.
class TableSortState {
  const TableSortState(this.column, {required this.descending});
  final String column;
  final bool descending;
}

/// Polling interval for the table view's optional auto-refresh. The
/// table view reloads its first page on each tick — no diff detection,
/// no scroll-position guesswork.
enum AutoRefreshInterval {
  off(null, 'Off'),
  s5(Duration(seconds: 5), '5s'),
  s30(Duration(seconds: 30), '30s'),
  m1(Duration(minutes: 1), '1m'),
  m5(Duration(minutes: 5), '5m');

  const AutoRefreshInterval(this.duration, this.label);

  final Duration? duration;
  final String label;
}

class TableTab extends TabModel {
  TableTab({
    super.id,
    required super.connectionId,
    required this.schema,
    required this.table,
    this.estimatedRows = -1,
    this.data,
    this.isLoading = false,
    this.error,
    this.elapsed,
    this.metaFilter,
  });
  final String schema;
  final String table;
  int estimatedRows;
  int? exactRows;

  GridData? data;
  bool isLoading;
  String? error;
  Duration? elapsed;
  TableSortState? sort;
  List<String> pkColumns = const [];
  var indexedColumns = <String>{};
  List<ColumnInfo> catalogColumns = const [];
  List<EditPolicy> editPolicies = const [];
  List<ForeignKey> foreignKeys = const [];
  AutoRefreshInterval autoRefresh = AutoRefreshInterval.off;
  GridViewMode viewMode = GridViewMode.typed;
  var hasNextPage = false;
  var isLoadingMore = false;

  /// When the table has a configured soft-delete column, include
  /// already-deleted rows in the result. Off by default — turning it on
  /// strips the `<col> IS NULL` filter; the Delete button still issues
  /// an UPDATE so users can soft-delete rows they explicitly want gone.
  var showDeleted = false;

  /// Soft-delete column that actually exists on this table (post-load).
  /// Null when no override is configured OR the override references a
  /// column that's no longer in the schema. Drives the visibility of
  /// the "Show deleted" toggle in the table header.
  String? effectiveSoftDeleteColumn;

  /// True when the connection profile's tenant filter applies to this
  /// table (the table has the configured column). Drives the "Tenant"
  /// badge in the header so users aren't surprised by reduced rows.
  var tenantFilterApplied = false;

  /// Index of the row currently selected in the grid. The right-side
  /// property inspector renders this row's fields. Null when nothing
  /// is selected.
  int? selectedRowIndex;

  /// Set when an `openTable` metadata action opened this tab.
  final MetaTableFilter? metaFilter;

  /// Columns the user (or metadata `default_hidden`) has collapsed. Null
  /// until the first load seeds it from the access-control defaults.
  Set<String>? hiddenColumns;

  /// The viewer's access to the table (schema metadata access control).
  AccessDecision tableAccess = AccessDecision.unrestricted;

  /// Metadata `display.defaultFilter` in force for the current load.
  String? defaultFilterApplied;

  /// A metadata default filter exists but waits for the user to trust the
  /// connection's metadata SQL.
  var defaultFilterPending = false;

  /// Message shown instead of a hard delete (metadata `danger: hardDelete`).
  String? hardDeleteRefusal;

  /// Message shown instead of any delete (metadata `danger: delete`).
  String? deleteRefusal;

  /// `INSERT … RETURNING` list matching the loaded columns.
  var returningList = '*';

  /// Whether the metadata Charts strip is expanded.
  var chartsOpen = false;

  /// The metadata snapshot (access policy) [data] was loaded under. A view
  /// that finds a different current snapshot reloads, so rows fetched under
  /// an older policy (before "View as…", a reload) never stay on screen.
  Object? loadedUnder;

  @override
  String get title => metaFilter == null ? '$schema.$table' : '$table · ${metaFilter!.label}';
}

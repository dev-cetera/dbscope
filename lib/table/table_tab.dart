import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../grid/data_grid.dart';
import '../tabs/tab_model.dart';

/// Sort state for a [TableTab]. Persisted with the tab so a refresh
/// keeps the user's chosen sort.
class TableSortState {
  final String column;
  final bool descending;
  const TableSortState(this.column, this.descending);
}

/// Polling interval for the table view's optional auto-refresh. The
/// table view reloads its first page on each tick — no diff detection,
/// no scroll-position guesswork.
enum AutoRefreshInterval {
  off(null, 'Off'),
  s5(Duration(seconds: 5), '5s'),
  s30(Duration(seconds: 30), '30s'),
  m1(Duration(minutes: 1), '1m'),
  m5(Duration(minutes: 5), '5m')
  ;

  final Duration? duration;
  final String label;
  const AutoRefreshInterval(this.duration, this.label);
}

class TableTab extends TabModel {
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
  Set<String> indexedColumns = <String>{};
  List<ColumnInfo> catalogColumns = const [];
  List<EditPolicy> editPolicies = const [];
  List<ForeignKey> foreignKeys = const [];
  AutoRefreshInterval autoRefresh = AutoRefreshInterval.off;
  GridViewMode viewMode = GridViewMode.typed;
  bool hasNextPage = false;
  bool isLoadingMore = false;

  /// When the table has a configured soft-delete column, include
  /// already-deleted rows in the result. Off by default — turning it on
  /// strips the `<col> IS NULL` filter; the Delete button still issues
  /// an UPDATE so users can soft-delete rows they explicitly want gone.
  bool showDeleted = false;

  /// Soft-delete column that actually exists on this table (post-load).
  /// Null when no override is configured OR the override references a
  /// column that's no longer in the schema. Drives the visibility of
  /// the "Show deleted" toggle in the table header.
  String? effectiveSoftDeleteColumn;

  /// True when the connection profile's tenant filter applies to this
  /// table (the table has the configured column). Drives the "Tenant"
  /// badge in the header so users aren't surprised by reduced rows.
  bool tenantFilterApplied = false;

  /// Index of the row currently selected in the grid. The right-side
  /// property inspector renders this row's fields. Null when nothing
  /// is selected.
  int? selectedRowIndex;

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
  });

  @override
  String get title => '$schema.$table';
}

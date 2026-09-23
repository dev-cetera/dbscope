import 'package:uuid/uuid.dart';

import '../catalog/schema_catalog.dart';
import '../grid/data_grid.dart';
import '../db/edit_policy.dart';
import '../query/pager.dart';
import '../shell/app_state.dart';

/// One column of the navigator. Sealed so the view can switch on the
/// concrete variant.
sealed class NavStep {
  final String id;
  NavStep({String? id}) : id = id ?? const Uuid().v4();
}

/// Root column: list of every table in the database. State (schemas /
/// tables / FKs) is loaded by the view from [SchemaCatalog] on demand —
/// we don't cache it on the step so it reflects the connection's current
/// catalog every time the column rebuilds.
class TableListStep extends NavStep {
  TableListStep({super.id});
}

/// Filter applied to a [RowListStep] when it was reached by clicking an
/// inbound-FK group on a parent row. Maps the FK columns of [source] to
/// the corresponding values of the parent row.
class InboundFilter {
  /// All [ForeignKey] entries that share a single logical constraint
  /// (composite FKs have one entry per column).
  final List<ForeignKey> source;

  /// Values of the parent row's target columns, in the same order as
  /// [source]. So `source[i].toColumn` in the parent has value [values][i].
  final List<Object?> values;

  const InboundFilter({required this.source, required this.values});

  String get constraintKey => source.first.constraintKey;
  String get sourceSchema => source.first.fromSchema;
  String get sourceTable => source.first.fromTable;
}

/// A column listing rows of one table — lazy-paginated via [KeysetPager],
/// rendered as the full [DataGrid]. Optionally filtered by an inbound-FK
/// from a parent row, plus an optional regex filter on a user-selected
/// column.
class RowListStep extends NavStep {
  final String schema;
  final String table;
  final InboundFilter? inboundFilter;

  /// Catalog metadata — populated once when the step loads.
  List<ColumnInfo> columns = const [];
  List<String> pkColumns = const [];
  Set<String> indexedColumns = const {};
  List<EditPolicy> editPolicies = const [];
  bool catalogLoaded = false;

  /// Live grid state.
  GridData? data;
  KeysetPager? pager;
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasNextPage = false;
  String? error;

  /// Sort applied via the grid header.
  TableSortState? sort;

  /// Regex filter state — applied as `(filterColumn)::text ~* '%pattern%'`.
  /// Empty pattern disables the filter. Null = `[AI Infer]` mode in the
  /// dropdown; the actual column to filter on then comes from
  /// [inferredColumn], set by RegexInferrer per-load.
  String? filterColumn;
  String filterPattern = '';

  /// Transient: the column the AI most recently inferred for this step.
  /// Used by `_load` when [filterColumn] is null so the dropdown can
  /// stay parked on `[AI Infer]` while subsequent searches re-infer
  /// against the same target list.
  String? inferredColumn;

  RowListStep({
    super.id,
    required this.schema,
    required this.table,
    this.inboundFilter,
  });
}

/// A column showing one row's `field: value` pairs. Tracks edit metadata
/// so cells can be edited inline.
class RowDetailStep extends NavStep {
  final String schema;
  final String table;
  final List<String> pkColumns;
  final List<Object?> pkValues;

  /// If reached by clicking an outbound-FK value on a parent row detail,
  /// the column name in the parent that was clicked. Lets the parent
  /// column highlight which field spawned us.
  final String? followedFromColumn;

  Map<String, Object?>? row;
  List<ColumnInfo> columns = const [];
  List<EditPolicy> editPolicies = const [];
  bool isLoading = false;
  String? error;

  RowDetailStep({
    super.id,
    required this.schema,
    required this.table,
    required this.pkColumns,
    required this.pkValues,
    this.followedFromColumn,
  });

  bool sameRowAs(RowDetailStep other) {
    if (schema != other.schema || table != other.table) return false;
    if (pkValues.length != other.pkValues.length) return false;
    for (var i = 0; i < pkValues.length; i++) {
      if (pkValues[i] != other.pkValues[i]) return false;
    }
    return true;
  }
}

class NavigatorTab extends TabModel {
  /// The path of columns shown to the right of the sidebar. Empty when
  /// the navigator was just opened and the user hasn't picked a table
  /// from the sidebar yet — the sidebar itself serves as the implicit
  /// "column 0" so we don't duplicate the table list inside the tab.
  final List<NavStep> steps = [];

  /// Cached FK catalog for the whole DB. Loaded once when the tab opens
  /// and reused by every column that needs to render FK chips / inbound
  /// groups. Refreshed via [reloadForeignKeys].
  List<ForeignKey> foreignKeys = const [];
  bool fksLoaded = false;
  String? fksError;

  /// Per-step widths, set when the user drags a column's resize handle.
  /// Step id → width in logical pixels.
  final Map<String, double> stepWidths = {};

  NavigatorTab({
    super.id,
    required super.connectionId,
  });

  void setStepWidth(String stepId, double w) {
    stepWidths[stepId] = w;
  }

  @override
  String get title {
    if (steps.isEmpty) return 'Navigator';
    final last = steps.last;
    if (last is RowDetailStep) {
      final pk = [
        for (var i = 0; i < last.pkColumns.length; i++)
          '${last.pkColumns[i]}=${last.pkValues[i]}',
      ].join(', ');
      return '${last.table}{$pk}';
    }
    if (last is RowListStep) {
      if (last.inboundFilter != null) {
        return '${last.table} ← ${last.inboundFilter!.constraintKey.split('.').last}';
      }
      return last.table;
    }
    return 'Navigator';
  }

  /// Replaces everything after [sourceIndex] with [next]. Use when the
  /// user clicks an item in column `sourceIndex` to spawn the next column.
  void pushFrom(int sourceIndex, NavStep next) {
    if (sourceIndex + 1 < steps.length) {
      steps.removeRange(sourceIndex + 1, steps.length);
    }
    steps.add(next);
  }

  /// Truncates the path so the column at [keepThroughIndex] is the last
  /// one shown. Used when the user clicks the already-selected item in a
  /// column to collapse everything after it.
  void truncateTo(int keepThroughIndex) {
    if (keepThroughIndex + 1 < steps.length) {
      steps.removeRange(keepThroughIndex + 1, steps.length);
    }
  }

  /// Returns the constraintKey of the inbound-FK group selected in the
  /// row-detail column at [index] (which spawned the next column).
  String? selectedInboundConstraintAt(int index) {
    if (index + 1 >= steps.length) return null;
    final next = steps[index + 1];
    if (next is! RowListStep) return null;
    return next.inboundFilter?.constraintKey;
  }

  /// Returns the followed FK column name in the row-detail column at
  /// [index] (i.e. which FK value was clicked to spawn the next column).
  String? selectedFollowedColumnAt(int index) {
    if (index + 1 >= steps.length) return null;
    final next = steps[index + 1];
    if (next is! RowDetailStep) return null;
    return next.followedFromColumn;
  }

  /// The PK values of the selected row in the row-list column at [index].
  List<Object?>? selectedRowPkValuesAt(int index) {
    if (index + 1 >= steps.length) return null;
    final next = steps[index + 1];
    if (next is RowDetailStep) return next.pkValues;
    return null;
  }

  /// The selected table name in the table-list column at [index].
  String? selectedTableAt(int index) {
    if (index + 1 >= steps.length) return null;
    final next = steps[index + 1];
    if (next is RowListStep) return '${next.schema}.${next.table}';
    return null;
  }
}

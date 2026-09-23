/// Spec for one column in a [GridData].
///
/// [TypeTag] is opaque to the grid — it carries whatever metadata the
/// caller needs to drive cell rendering and editing (e.g. a Postgres
/// type enum, a CSV-column-kind enum, or just `void` when types don't
/// matter). The grid passes it through to the [CellRenderer] /
/// [CellEditor] without inspecting it.
class GridColumnSpec<TypeTag> {
  /// Column header text + key used for keyed lookups. Must be unique
  /// inside one [GridData].
  final String name;

  /// Caller-defined type tag. Pulled into render/edit contexts but
  /// otherwise ignored by the grid.
  final TypeTag? type;

  /// Subtitle shown under the column name in the header. Usually a
  /// type label like "varchar" or "Int64". Empty hides the subtitle.
  final String typeLabel;

  /// Adds a "PK" badge in the header.
  final bool primaryKey;

  /// Adds an "IDX" badge in the header (suppressed when [primaryKey]).
  final bool indexed;

  /// Default column width in logical pixels. Null falls back to the
  /// grid's [DataGrid.defaultColumnWidth].
  final double? defaultWidth;

  const GridColumnSpec({
    required this.name,
    this.type,
    this.typeLabel = '',
    this.primaryKey = false,
    this.indexed = false,
    this.defaultWidth,
  });
}

/// The grid's data container: columns + 2D row matrix. Rows are
/// mutable lists so the [DataGridController] can patch them in place
/// without rebuilding the matrix.
class GridData<TypeTag> {
  final List<GridColumnSpec<TypeTag>> columns;
  final List<List<Object?>> rows;
  const GridData({required this.columns, required this.rows});
}

/// Fired when a cell commit produces a new value different from the
/// old one. Caller persists it (e.g. via DML) and pushes the
/// confirmed value back through [DataGridController.updateCell].
class GridEditEvent {
  final int rowIdx;
  final String column;
  final Object? oldValue;
  final Object? newValueRaw;
  GridEditEvent(this.rowIdx, this.column, this.oldValue, this.newValueRaw);
}

/// Fired when a header click flips sort. The grid is purely
/// view-state; the caller re-fetches data in the new order.
class GridSortEvent {
  final String column;
  final bool descending;
  GridSortEvent(this.column, this.descending);
}

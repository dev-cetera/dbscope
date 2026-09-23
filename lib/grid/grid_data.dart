// Powerdb-shaped re-exports of the generic data_grid package types,
// parameterised over PgType. The rest of the app imports from here
// (not the package directly) so existing call sites that say
// `GridColumnSpec(...)`, `GridData(...)`, `DataGridController()` keep
// working without explicit type arguments.

import 'package:data_grid/data_grid.dart' as g;

import '../catalog/pg_type.dart';

export 'package:data_grid/data_grid.dart'
    show GridEditEvent, GridSortEvent, GridStyle, GridStyleExtension, CellRange;

/// How the grid renders cells. New modes plug in by adding an enum
/// value and a branch in `PgTypeCellRenderer`.
enum GridViewMode {
  table('Table'),
  typed('Typed')
  ;

  final String label;
  const GridViewMode(this.label);
}

/// Powerdb's column spec — `data_grid` parameterised over [PgType].
typedef GridColumnSpec = g.GridColumnSpec<PgType>;

/// Powerdb's grid data container.
typedef GridData = g.GridData<PgType>;

/// Powerdb's controller — pre-typed so callers can write
/// `DataGridController()` without specifying the type argument.
class DataGridController extends g.DataGridController<PgType> {}

/// Convenience getters that keep the older dbscope-side names working
/// on the generic [g.GridColumnSpec<PgType>].
extension PgColumnSpecX on g.GridColumnSpec<PgType> {
  /// Non-null Postgres type — column specs that came through dbscope
  /// always have one; this guard makes that visible to the type
  /// checker.
  PgType get pgType => type ?? PgType.unknown;

  /// Alias of [typeLabel] retained for older code paths.
  String get typeName => typeLabel;
}

/// Factory that builds a [GridColumnSpec] with dbscope's older
/// keyword names. New code can use the package constructor directly.
GridColumnSpec gridColumn({
  required String name,
  required PgType type,
  String typeName = '',
  bool primaryKey = false,
  bool indexed = false,
  double? defaultWidth,
}) => g.GridColumnSpec<PgType>(
  name: name,
  type: type,
  typeLabel: typeName,
  primaryKey: primaryKey,
  indexed: indexed,
  defaultWidth: defaultWidth,
);

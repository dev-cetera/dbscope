/// Hand-rolled high-performance data grid widget for Flutter.
///
/// Drives multi-column tabular UIs with drag-range selection, column
/// reorder/resize, pluggable cell renderers + editors, TSV / RFC-4180
/// CSV copy-to-clipboard, and an imperative [DataGridController] for
/// incremental row updates so it scales past the 10k-row mark without
/// rebuilding the world.
///
/// Backend-agnostic: column type tags are an opaque generic, so the
/// same widget renders Postgres, SQLite, CSV, or any other tabular
/// source given an appropriate [CellRenderer] / [CellEditor] pair.
library;

export 'src/cell_editor.dart';
export 'src/cell_overlay.dart';
export 'src/cell_range.dart';
export 'src/cell_renderer.dart';
export 'src/data_grid.dart';
export 'src/grid_data.dart';
export 'src/grid_model.dart';
export 'src/grid_style.dart';
export 'src/serialize.dart';

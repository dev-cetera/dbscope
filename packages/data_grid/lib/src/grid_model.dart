import 'package:flutter/foundation.dart';

import 'cell_range.dart';

/// Mutable view-state for [DataGrid]. Owns column order/width
/// overrides + the current selection + which cell (if any) is
/// currently being edited.
///
/// Not the source of truth for the data itself — `GridData.rows`/
/// `GridData.columns` are owned by the caller and passed in via the
/// widget; the model holds purely UI state derived from "there are N
/// columns and M rows".
class GridModel extends ChangeNotifier {
  /// View-order of columns, expressed as indices into the original
  /// `GridData.columns` list. `_order[visiblePos] = originalIndex`.
  List<int> _order = const [];
  List<double> _widths = const [];
  CellRange? _selection;
  int _columnCount = 0;
  int _rowCount = 0;

  /// Row+col currently being edited (one cell at a time — the focused
  /// cell of the current selection). Both null when no edit is in
  /// progress.
  int? _editingRow;
  int? _editingCol;

  /// Min/max column width clamps. Adjust on construction for grids
  /// with unusually narrow or wide columns.
  final double minColumnWidth;
  final double maxColumnWidth;

  GridModel({
    this.minColumnWidth = 40,
    this.maxColumnWidth = 1600,
  });

  List<int> get order => _order;
  List<double> get widths => _widths;
  CellRange? get selection => _selection;
  int get columnCount => _columnCount;
  int get rowCount => _rowCount;
  bool get hasSelection => _selection != null;
  int? get editingRow => _editingRow;
  int? get editingCol => _editingCol;
  bool get isEditing => _editingRow != null;

  /// Convert a view-position to the original column index.
  int viewToOriginal(int viewIdx) => _order[viewIdx];

  /// Convert an original column index to its current view-position.
  /// Returns -1 if the column was removed.
  int originalToView(int originalIdx) => _order.indexOf(originalIdx);

  double widthAt(int viewIdx) => _widths[_order[viewIdx]];

  double get totalWidth {
    var sum = 0.0;
    for (final w in _widths) {
      sum += w;
    }
    return sum;
  }

  /// Initialise / reset the model when the underlying columns change.
  /// Preserves selection only if it still fits.
  void resetColumns(int columnCount, List<double> defaultWidths) {
    assert(defaultWidths.length == columnCount);
    _columnCount = columnCount;
    _order = List<int>.generate(columnCount, (i) => i);
    _widths = List<double>.of(defaultWidths);
    _clampSelection();
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  void setRowCount(int rowCount) {
    if (_rowCount == rowCount) return;
    _rowCount = rowCount;
    _clampSelection();
    notifyListeners();
  }

  void setColumnWidth(int originalIdx, double width) {
    if (originalIdx < 0 || originalIdx >= _widths.length) return;
    _widths[originalIdx] = width.clamp(minColumnWidth, maxColumnWidth);
    notifyListeners();
  }

  /// Reorder by moving the column at [fromViewIdx] so that it lands at
  /// [toViewIdx] in the visible order.
  void reorderColumn(int fromViewIdx, int toViewIdx) {
    if (fromViewIdx == toViewIdx) return;
    final clampedFrom = fromViewIdx.clamp(0, _order.length - 1);
    final clampedTo = toViewIdx.clamp(0, _order.length - 1);
    final col = _order.removeAt(clampedFrom);
    _order.insert(clampedTo, col);
    notifyListeners();
  }

  void selectSingle(int row, int col) {
    if (!_inBounds(row, col)) return;
    _selection = CellRange.singleCell(row, col);
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  void extendSelection(int row, int col) {
    if (!_inBounds(row, col)) return;
    final current = _selection;
    if (current == null) {
      _selection = CellRange.singleCell(row, col);
    } else {
      _selection = current.withFocus(row, col);
    }
    notifyListeners();
  }

  void selectRow(int row) {
    if (row < 0 || row >= _rowCount) return;
    if (_order.isEmpty) return;
    _selection = CellRange(
      anchorRow: row,
      anchorCol: 0,
      focusRow: row,
      focusCol: _order.length - 1,
    );
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  void clearSelection() {
    if (_selection == null && _editingRow == null) return;
    _selection = null;
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  void beginEdit(int row, int col) {
    if (!_inBounds(row, col)) return;
    _selection = CellRange.singleCell(row, col);
    _editingRow = row;
    _editingCol = col;
    notifyListeners();
  }

  void endEdit() {
    if (_editingRow == null && _editingCol == null) return;
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  bool _inBounds(int row, int col) =>
      row >= 0 && row < _rowCount && col >= 0 && col < _order.length;

  void _clampSelection() {
    final s = _selection;
    if (s == null) return;
    if (_rowCount == 0 || _order.isEmpty) {
      _selection = null;
      _editingRow = null;
      _editingCol = null;
      return;
    }
    final maxRow = _rowCount - 1;
    final maxCol = _order.length - 1;
    if (s.anchorRow > maxRow ||
        s.focusRow > maxRow ||
        s.anchorCol > maxCol ||
        s.focusCol > maxCol) {
      _selection = null;
      _editingRow = null;
      _editingCol = null;
    }
  }
}

/// @docImport '../data_grid.dart';
library;

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
  GridModel({
    this.minColumnWidth = 40,
    this.maxColumnWidth = 1600,
  });

  /// View-order of columns, expressed as indices into the original
  /// `GridData.columns` list. `_order[visiblePos] = originalIndex`.
  List<int> _order = const [];
  List<double> _widths = const [];
  CellRange? _selection;
  var _columnCount = 0;
  var _rowCount = 0;

  /// Row+col currently being edited (one cell at a time — the focused
  /// cell of the current selection). Both null when no edit is in
  /// progress.
  int? _editingRow;
  int? _editingCol;

  /// Min/max column width clamps. Adjust on construction for grids
  /// with unusually narrow or wide columns.
  final double minColumnWidth;
  final double maxColumnWidth;

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

  /// Width of the VISIBLE columns (hidden ones take no space).
  double get totalWidth {
    var sum = 0.0;
    for (final i in _order) {
      sum += _widths[i];
    }
    return sum;
  }

  /// Initialise / reset the model when the underlying columns change.
  /// Preserves selection only if it still fits.
  void resetColumns(
    int columnCount,
    List<double> defaultWidths, {
    Set<int> hidden = const {},
  }) {
    assert(
      defaultWidths.length == columnCount,
      'defaultWidths needs one entry per column',
    );
    _columnCount = columnCount;
    _order = [
      for (var i = 0; i < columnCount; i++)
        if (!hidden.contains(i)) i,
    ];
    _widths = List<double>.of(defaultWidths);
    _clampSelection();
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  /// Show/hide columns (by original index) without touching widths. Kept
  /// columns stay in their current view order; re-shown columns return at
  /// their original position relative to the others.
  void setHidden(Set<int> hidden) {
    final kept = [
      for (final i in _order)
        if (!hidden.contains(i)) i,
    ];
    final shown = [
      for (var i = 0; i < _columnCount; i++)
        if (!hidden.contains(i) && !kept.contains(i)) i,
    ];
    for (final i in shown) {
      final insertAt = kept.indexWhere((keptIndex) => keptIndex > i);
      if (insertAt < 0) {
        kept.add(i);
      } else {
        kept.insert(insertAt, i);
      }
    }
    _order = kept;
    // Selection and edit positions are VIEW indices; after the columns move
    // they'd point at different columns (an in-progress edit could commit
    // into the wrong one), so drop them.
    _selection = null;
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

  /// [count] rows were removed at [start]. Selection and edit positions
  /// are data-row indices, so they follow their row; one that touched a
  /// removed row is dropped. Without this a delete left the selection —
  /// and whatever reads it, like an inspector — on the row below.
  void rowsRemoved(int start, int count) {
    _rowCount -= count;
    int? follow(int row) => row < start
        ? row
        : row < start + count
        ? null
        : row - count;
    _moveRows(follow);
  }

  /// [count] rows were inserted at [start]; positions at or below it
  /// move down with their row.
  void rowsInserted(int start, int count) {
    _rowCount += count;
    _moveRows((row) => row < start ? row : row + count);
  }

  void _moveRows(int? Function(int row) follow) {
    final selection = _selection;
    if (selection != null) {
      final anchor = follow(selection.anchorRow);
      final focus = follow(selection.focusRow);
      _selection = anchor == null || focus == null
          ? null
          : CellRange(
              anchorRow: anchor,
              anchorCol: selection.anchorCol,
              focusRow: focus,
              focusCol: selection.focusCol,
            );
    }
    final editingRow = _editingRow;
    if (editingRow != null) {
      _editingRow = follow(editingRow);
      if (_editingRow == null) _editingCol = null;
    }
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
    final movedColumn = _order.removeAt(clampedFrom);
    _order.insert(clampedTo, movedColumn);
    notifyListeners();
  }

  void selectSingle(int row, int column) {
    if (!_inBounds(row, column)) return;
    _selection = CellRange.singleCell(row, column);
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  void extendSelection(int row, int column) {
    if (!_inBounds(row, column)) return;
    final current = _selection;
    if (current == null) {
      _selection = CellRange.singleCell(row, column);
    } else {
      _selection = current.withFocus(row, column);
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

  void beginEdit(int row, int column) {
    if (!_inBounds(row, column)) return;
    _selection = CellRange.singleCell(row, column);
    _editingRow = row;
    _editingCol = column;
    notifyListeners();
  }

  void endEdit() {
    if (_editingRow == null && _editingCol == null) return;
    _editingRow = null;
    _editingCol = null;
    notifyListeners();
  }

  bool _inBounds(int row, int column) =>
      row >= 0 && row < _rowCount && column >= 0 && column < _order.length;

  void _clampSelection() {
    final selection = _selection;
    if (selection == null) return;
    if (_rowCount == 0 || _order.isEmpty) {
      _selection = null;
      _editingRow = null;
      _editingCol = null;
      return;
    }
    final maxRow = _rowCount - 1;
    final maxColumn = _order.length - 1;
    if (selection.anchorRow > maxRow ||
        selection.focusRow > maxRow ||
        selection.anchorCol > maxColumn ||
        selection.focusCol > maxColumn) {
      _selection = null;
      _editingRow = null;
      _editingCol = null;
    }
  }
}

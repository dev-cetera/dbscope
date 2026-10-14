import 'package:flutter/foundation.dart';

/// Anchor + active corners of the current selection rectangle. Cells
/// inside `[min(anchor, focus), max(anchor, focus)]` (per-axis) are
/// considered selected.
@immutable
class CellRange {
  const CellRange({
    required this.anchorRow,
    required this.anchorCol,
    required this.focusRow,
    required this.focusCol,
  });

  factory CellRange.singleCell(int row, int column) => CellRange(
        anchorRow: row,
        anchorCol: column,
        focusRow: row,
        focusCol: column,
      );

  final int anchorRow;
  final int anchorCol;
  final int focusRow;
  final int focusCol;

  int get rowMin => anchorRow < focusRow ? anchorRow : focusRow;
  int get rowMax => anchorRow > focusRow ? anchorRow : focusRow;
  int get colMin => anchorCol < focusCol ? anchorCol : focusCol;
  int get colMax => anchorCol > focusCol ? anchorCol : focusCol;

  bool contains(int row, int column) =>
      row >= rowMin && row <= rowMax && column >= colMin && column <= colMax;

  bool get isSingleCell => anchorRow == focusRow && anchorCol == focusCol;
  int get rowCount => rowMax - rowMin + 1;
  int get colCount => colMax - colMin + 1;

  CellRange withFocus(int row, int column) => CellRange(
        anchorRow: anchorRow,
        anchorCol: anchorCol,
        focusRow: row,
        focusCol: column,
      );
}

import 'package:flutter/foundation.dart';

/// Anchor + active corners of the current selection rectangle. Cells
/// inside `[min(anchor, focus), max(anchor, focus)]` (per-axis) are
/// considered selected.
@immutable
class CellRange {
  final int anchorRow;
  final int anchorCol;
  final int focusRow;
  final int focusCol;

  const CellRange({
    required this.anchorRow,
    required this.anchorCol,
    required this.focusRow,
    required this.focusCol,
  });

  int get rowMin => anchorRow < focusRow ? anchorRow : focusRow;
  int get rowMax => anchorRow > focusRow ? anchorRow : focusRow;
  int get colMin => anchorCol < focusCol ? anchorCol : focusCol;
  int get colMax => anchorCol > focusCol ? anchorCol : focusCol;

  bool contains(int row, int col) =>
      row >= rowMin && row <= rowMax && col >= colMin && col <= colMax;

  bool get isSingleCell => anchorRow == focusRow && anchorCol == focusCol;
  int get rowCount => rowMax - rowMin + 1;
  int get colCount => colMax - colMin + 1;

  CellRange withFocus(int row, int col) => CellRange(
        anchorRow: anchorRow,
        anchorCol: anchorCol,
        focusRow: row,
        focusCol: col,
      );

  static CellRange singleCell(int row, int col) => CellRange(
        anchorRow: row,
        anchorCol: col,
        focusRow: row,
        focusCol: col,
      );
}

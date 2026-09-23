import 'package:flutter/widgets.dart';

import 'grid_data.dart';

/// Optional decoration on top of a rendered cell. Used by dbscope to
/// draw FK link chips, by other apps to draw lint badges, etc.
///
/// The provider returns null for cells that need no overlay.
abstract class CellOverlayProvider<TypeTag> {
  const CellOverlayProvider();

  /// Build the overlay for this cell, or return null to skip it. The
  /// grid layers the result on top of the cell renderer's output.
  Widget? build(BuildContext context, CellOverlayContext<TypeTag> ctx);
}

class CellOverlayContext<TypeTag> {
  final int rowIdx;
  final int originalIdx;
  final GridColumnSpec<TypeTag> column;
  final Object? value;
  const CellOverlayContext({
    required this.rowIdx,
    required this.originalIdx,
    required this.column,
    required this.value,
  });
}

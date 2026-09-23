import 'package:flutter/material.dart';

import '../grid_data.dart';
import '../grid_model.dart';
import '../grid_style.dart';

/// Column-header row. Each header is a draggable handle for reorder
/// and has a resize handle on its right edge. Click toggles sort.
class GridHeader<TypeTag> extends StatelessWidget {
  final GridData<TypeTag> data;
  final GridModel model;
  final GridStyle style;
  final double height;
  final String? sortColumn;
  final bool sortDescending;
  final void Function(int originalIdx)? onSortToggle;
  final void Function(int originalIdx, double width) onWidthChanged;
  final void Function(int fromView, int toView) onReorder;

  const GridHeader({
    super.key,
    required this.data,
    required this.model,
    required this.style,
    required this.height,
    required this.sortColumn,
    required this.sortDescending,
    required this.onSortToggle,
    required this.onWidthChanged,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: style.headerBackground,
        border: Border(
          bottom: BorderSide(color: style.headerBorderStrong),
        ),
      ),
      child: Row(
        children: [
          for (var v = 0; v < model.order.length; v++)
            _HeaderCell<TypeTag>(
              viewIdx: v,
              originalIdx: model.viewToOriginal(v),
              spec: data.columns[model.viewToOriginal(v)],
              width: model.widthAt(v),
              height: height,
              style: style,
              isSorted:
                  sortColumn == data.columns[model.viewToOriginal(v)].name,
              sortDescending: sortDescending,
              onSortToggle: onSortToggle,
              onWidthChanged: onWidthChanged,
              onReorder: onReorder,
            ),
        ],
      ),
    );
  }
}

class _HeaderCell<TypeTag> extends StatelessWidget {
  final int viewIdx;
  final int originalIdx;
  final GridColumnSpec<TypeTag> spec;
  final double width;
  final double height;
  final GridStyle style;
  final bool isSorted;
  final bool sortDescending;
  final void Function(int originalIdx)? onSortToggle;
  final void Function(int originalIdx, double width) onWidthChanged;
  final void Function(int fromView, int toView) onReorder;

  const _HeaderCell({
    required this.viewIdx,
    required this.originalIdx,
    required this.spec,
    required this.width,
    required this.height,
    required this.style,
    required this.isSorted,
    required this.sortDescending,
    required this.onSortToggle,
    required this.onWidthChanged,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final badges = <String>[
      if (spec.primaryKey) 'PK',
      if (spec.indexed && !spec.primaryKey) 'IDX',
    ];

    final body = Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: style.cellBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        spec.name,
                        style: style.headerTitleStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badges.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          badges.join('/'),
                          style: style.headerSubtitleStyle.copyWith(
                            color: style.accent,
                          ),
                        ),
                      ),
                    if (isSorted)
                      Icon(
                        sortDescending
                            ? Icons.arrow_drop_down
                            : Icons.arrow_drop_up,
                        size: 14,
                        color: style.textColor,
                      ),
                  ],
                ),
                if (spec.typeLabel.isNotEmpty)
                  Text(
                    spec.typeLabel,
                    style: style.headerSubtitleStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    final draggable = Draggable<int>(
      data: viewIdx,
      axis: Axis.horizontal,
      feedback: Material(
        elevation: 4,
        color: style.headerBackground,
        child: SizedBox(
          width: width,
          height: height,
          child: Opacity(opacity: 0.85, child: body),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: body),
      child: GestureDetector(
        onTap: onSortToggle == null ? null : () => onSortToggle!(originalIdx),
        child: body,
      ),
    );

    final dropTarget = DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != viewIdx,
      onAcceptWithDetails: (d) => onReorder(d.data, viewIdx),
      builder: (ctx, candidate, rejected) {
        return Stack(
          children: [
            draggable,
            if (candidate.isNotEmpty)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 2,
                child: Container(color: style.accent),
              ),
          ],
        );
      },
    );

    return Stack(
      children: [
        dropTarget,
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 6,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) =>
                  onWidthChanged(originalIdx, width + d.delta.dx),
            ),
          ),
        ),
      ],
    );
  }
}

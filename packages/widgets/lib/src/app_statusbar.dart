import 'package:flutter/material.dart';

import 'chrome.dart';
import 'palette.dart';

/// Bottom strip of cells. Under bevel mode each cell is a sunken Win95 panel;
/// under flat mode the strip carries a 1px top border and cells are plain.
class AppStatusBar extends StatelessWidget {
  const AppStatusBar({super.key, required this.segments});

  final List<String> segments;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final cells = segments.where((segment) => segment.isNotEmpty).toList();
    return SelectionArea(
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          border:
              palette.isBevel
                  ? null
                  : Border(top: BorderSide(color: palette.border)),
        ),
        padding: const EdgeInsets.fromLTRB(2.0, 2.0, 2.0, 2.0),
        child: Row(
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              Flexible(flex: i == 0 ? 6 : 2, child: _cell(palette, cells[i])),
              if (i < cells.length - 1) const SizedBox(width: 2.0),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cell(AppPalette palette, String text) {
    final label = Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: palette.bodyFontSize,
        fontFamily: palette.uiFontFamily,
        color: palette.text,
      ),
    );
    const cellPadding = EdgeInsets.symmetric(horizontal: 4.0, vertical: 1.0);
    return palette.isBevel
        ? bevelBox(
          palette: palette,
          sunken: true,
          background: palette.surface,
          padding: cellPadding,
          child: label,
        )
        : Padding(padding: cellPadding, child: label);
  }
}

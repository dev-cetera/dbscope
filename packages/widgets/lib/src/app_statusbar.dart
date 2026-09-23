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
    final p = AppPalette.of(context);
    final cells = segments.where((s) => s.isNotEmpty).toList();
    return SelectionArea(
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          border:
              p.isBevel
                  ? null
                  : Border(top: BorderSide(color: p.border, width: 1)),
        ),
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
        child: Row(
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              Flexible(flex: i == 0 ? 6 : 2, child: _cell(p, cells[i])),
              if (i < cells.length - 1) const SizedBox(width: 2),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cell(AppPalette p, String text) {
    final label = Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: p.bodyFontSize,
        fontFamily: p.uiFontFamily,
        color: p.text,
      ),
    );
    const cellPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 1);
    return p.isBevel
        ? bevelBox(
          palette: p,
          sunken: true,
          background: p.surface,
          padding: cellPadding,
          child: label,
        )
        : Padding(padding: cellPadding, child: label);
  }
}

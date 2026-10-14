import 'package:flutter/material.dart';

import 'chrome.dart';
import 'palette.dart';

/// Compact stat readout: big accent-colored value, small label below.
/// Sunken bevel under bevel mode, rounded card under flat mode.
class MetricChip extends StatelessWidget {
  const MetricChip({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.width = 70,
  });

  final String label;
  final String value;
  final String? unit;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: palette.bodyFontSize + 7,
              fontFamily: palette.uiFontFamily,
              fontWeight: FontWeight.w700,
              color: palette.accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: palette.smallFontSize,
                  fontFamily: palette.uiFontFamily,
                  color: palette.text,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unit != null)
              Text(
                unit!,
                style: TextStyle(
                  fontSize: palette.smallFontSize,
                  fontFamily: palette.uiFontFamily,
                  color: palette.mutedText,
                ),
              ),
          ],
        ),
      ],
    );

    const inset = EdgeInsets.symmetric(horizontal: 4.0, vertical: 3.0);
    return SizedBox(
      width: width,
      child:
          palette.isBevel
              ? bevelBox(
                palette: palette,
                sunken: true,
                background: palette.surface,
                padding: inset,
                child: body,
              )
              : flatBox(
                palette: palette,
                background: palette.surfaceRaised,
                padding: inset,
                child: body,
              ),
    );
  }
}

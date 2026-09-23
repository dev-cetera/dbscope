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
    final p = AppPalette.of(context);
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
              fontSize: p.bodyFontSize + 7,
              fontFamily: p.uiFontFamily,
              fontWeight: FontWeight.w700,
              color: p.accent,
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
                  fontSize: p.smallFontSize,
                  fontFamily: p.uiFontFamily,
                  color: p.text,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unit != null)
              Text(
                unit!,
                style: TextStyle(
                  fontSize: p.smallFontSize,
                  fontFamily: p.uiFontFamily,
                  color: p.mutedText,
                ),
              ),
          ],
        ),
      ],
    );

    const inset = EdgeInsets.symmetric(horizontal: 4, vertical: 3);
    return SizedBox(
      width: width,
      child:
          p.isBevel
              ? bevelBox(
                palette: p,
                sunken: true,
                background: p.surface,
                padding: inset,
                child: body,
              )
              : flatBox(
                palette: p,
                background: p.surfaceRaised,
                padding: inset,
                child: body,
              ),
    );
  }
}

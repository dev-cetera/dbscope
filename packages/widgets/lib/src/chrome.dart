import 'package:flutter/material.dart';

import 'palette.dart';

/// 4-layer Win95 bevel. Used by App* widgets in bevel mode.
Widget bevelBox({
  required AppPalette palette,
  required bool sunken,
  required Widget child,
  Color? background,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
}) {
  final outerTopLeft = sunken ? palette.border : palette.bevelHighlight;
  final outerBottomRight =
      sunken ? palette.bevelHighlight : palette.borderStrong;
  final innerTopLeft = sunken ? palette.borderStrong : palette.surfaceRaised;
  final innerBottomRight = sunken ? palette.surfaceRaised : palette.border;

  return Container(
    decoration: BoxDecoration(
      color: background,
      border: Border(
        top: BorderSide(color: outerTopLeft, width: 1),
        left: BorderSide(color: outerTopLeft, width: 1),
        right: BorderSide(color: outerBottomRight, width: 1),
        bottom: BorderSide(color: outerBottomRight, width: 1),
      ),
    ),
    child: Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: innerTopLeft, width: 1),
          left: BorderSide(color: innerTopLeft, width: 1),
          right: BorderSide(color: innerBottomRight, width: 1),
          bottom: BorderSide(color: innerBottomRight, width: 1),
        ),
      ),
      padding: padding,
      child: child,
    ),
  );
}

/// Plain rounded rect with 1px border. Used by App* widgets in flat mode.
Widget flatBox({
  required AppPalette palette,
  required Widget child,
  Color? background,
  Color? borderColor,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
}) {
  return Container(
    decoration: BoxDecoration(
      color: background ?? palette.surfaceRaised,
      borderRadius: BorderRadius.circular(palette.cornerRadius),
      border: Border.all(color: borderColor ?? palette.border, width: 1),
    ),
    padding: padding,
    child: child,
  );
}

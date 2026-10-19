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
  final outerBottomRight = sunken ? palette.bevelHighlight : palette.borderStrong;
  final innerTopLeft = sunken ? palette.borderStrong : palette.surfaceRaised;
  final innerBottomRight = sunken ? palette.surfaceRaised : palette.border;

  return Container(
    decoration: BoxDecoration(
      color: background,
      border: Border(
        top: BorderSide(color: outerTopLeft),
        left: BorderSide(color: outerTopLeft),
        right: BorderSide(color: outerBottomRight),
        bottom: BorderSide(color: outerBottomRight),
      ),
    ),
    child: Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: innerTopLeft),
          left: BorderSide(color: innerTopLeft),
          right: BorderSide(color: innerBottomRight),
          bottom: BorderSide(color: innerBottomRight),
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
      border: Border.all(color: borderColor ?? palette.border),
    ),
    padding: padding,
    child: child,
  );
}

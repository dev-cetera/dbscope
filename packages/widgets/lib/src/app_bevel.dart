import 'package:flutter/material.dart';

import 'chrome.dart';
import 'palette.dart';

/// Theme-aware container that draws as a Windows 95 4-layer bevel under
/// [ChromeKind.bevel] palettes and as a rounded card with a 1px border under
/// [ChromeKind.flat] palettes.
class AppBevel extends StatelessWidget {
  final Widget child;
  final bool raised;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const AppBevel({
    super.key,
    required this.child,
    this.raised = true,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    if (palette.isBevel) {
      return bevelBox(
        palette: palette,
        sunken: !raised,
        background: color ?? palette.surface,
        padding: padding,
        child: child,
      );
    }
    return flatBox(
      palette: palette,
      background:
          color ?? (raised ? palette.surfaceRaised : palette.surfaceRecessed),
      padding: padding,
      child: child,
    );
  }
}

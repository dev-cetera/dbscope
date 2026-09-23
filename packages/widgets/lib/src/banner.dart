import 'package:flutter/material.dart';

/// Severity of an [AppBanner]. Controls background and foreground colors.
enum BannerSeverity {
  /// Quiet hint (`surfaceContainerHigh` + body text). For inline help text
  /// like "Double-click a cell to edit."
  hint,

  /// Information (`primaryContainer`). For advisories the user should see
  /// but that don't block the next action.
  info,

  /// Hard error (`errorContainer`). For conditions that block the next
  /// action.
  error,
}

/// A full-width colored bar that sits above a panel's content. Use this
/// for any "info bar" strip below a header instead of an ad-hoc
/// `Container(color: ..., child: Text(...))`.
class AppBanner extends StatelessWidget {
  final String message;
  final BannerSeverity severity;

  /// Smaller padding + smaller font, for secondary advisories.
  final bool dense;

  const AppBanner({
    super.key,
    required this.message,
    this.severity = BannerSeverity.hint,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = switch (severity) {
      BannerSeverity.hint => (
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.onSurface,
      ),
      BannerSeverity.info => (
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      BannerSeverity.error => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };
    return Container(
      width: double.infinity,
      color: bg,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 6,
      ),
      child: Text(
        message,
        style: TextStyle(
          color: fg,
          fontSize: dense ? 11 : 12,
          fontWeight:
              severity == BannerSeverity.hint
                  ? FontWeight.normal
                  : FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

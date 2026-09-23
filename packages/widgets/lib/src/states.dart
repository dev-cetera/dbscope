import 'package:flutter/material.dart';

/// Centered "nothing to show" placeholder: a faded icon and a message.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  /// Larger icon for full-area empty states; smaller for side panels.
  final double iconSize;

  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.iconSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: theme.hintColor.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Failure surface: an error message in [theme.colorScheme.error] plus
/// an optional retry button. The retry button is omitted when [onRetry]
/// is null (e.g. errors that the user has to resolve elsewhere first).
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            message,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 14),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// Centered indeterminate spinner with consistent padding. Use this
/// instead of bare `CircularProgressIndicator()` so loading states look
/// the same everywhere.
class LoadingView extends StatelessWidget {
  final double size;
  final double padding;
  const LoadingView({super.key, this.size = 24, this.padding = 16});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(strokeWidth: size <= 18 ? 2 : 3),
        ),
      ),
    );
  }
}

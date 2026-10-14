import 'package:flutter/material.dart';

/// How long a toast message stays on screen before it disappears.
const _kToastDuration = Duration(seconds: 3);

/// Show a transient message in the bottom snack bar.
void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: _kToastDuration),
  );
}

/// Two-button confirmation dialog. Returns `true` if the user confirms.
///
/// Standard shape: title + body, Cancel (TextButton) on the left,
/// primary action (FilledButton) on the right. When [destructive] is
/// true the primary action is themed with the error palette so deletes
/// stand out.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final confirm =
          destructive
              ? FilledButton(
                style: FilledButton.styleFrom(
                  foregroundColor: theme.colorScheme.onErrorContainer,
                  backgroundColor: theme.colorScheme.errorContainer,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              )
              : FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              );
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          confirm,
        ],
      );
    },
  );
  return ok ?? false;
}

import 'package:flutter/material.dart';

/// Single entry for [showAppContextMenu]. Use [AppMenuEntry.divider] to
/// insert a separator between groups. A null [value] also acts as
/// non-selectable.
class AppMenuEntry<T> {
  final T? value;
  final String? label;
  final IconData? icon;
  final bool enabled;
  final bool destructive;
  final bool divider;

  const AppMenuEntry({
    this.value,
    this.label,
    this.icon,
    this.enabled = true,
    this.destructive = false,
  }) : divider = false;

  const AppMenuEntry.divider()
    : value = null,
      label = null,
      icon = null,
      enabled = false,
      destructive = false,
      divider = true;
}

/// Shared right-click / long-press context menu. Pass [globalPosition]
/// from the gesture detector (`details.globalPosition`); positioning is
/// computed against the nearest overlay so the menu appears under the
/// pointer regardless of which window the click came from.
///
/// Returns the [AppMenuEntry.value] of the chosen item, or null when
/// dismissed. Headers / dividers are never returned.
Future<T?> showAppContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<AppMenuEntry<T>> items,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;
  final theme = Theme.of(context);
  final entries = <PopupMenuEntry<T>>[];
  for (final e in items) {
    if (e.divider) {
      entries.add(const PopupMenuDivider());
      continue;
    }
    entries.add(
      PopupMenuItem<T>(
        value: e.value,
        enabled: e.enabled && e.value != null,
        height: 32,
        child: Row(
          children: [
            if (e.icon != null) ...[
              Icon(
                e.icon,
                size: 14,
                color: e.destructive ? theme.colorScheme.error : null,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                e.label ?? '',
                style: TextStyle(
                  color: e.destructive ? theme.colorScheme.error : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  if (entries.isEmpty) return null;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: entries,
  );
}

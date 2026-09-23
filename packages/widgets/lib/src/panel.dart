import 'package:flutter/material.dart';

/// A panel-shaped container: a header bar (icon + title + subtitle +
/// trailing actions), an optional filter strip, a divider, and a body.
///
/// Centralises the surface color, padding, font sizes, and border so
/// they don't drift per call-site.
class AppPanel extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final IconData? titleIcon;
  final Widget? trailing;
  final Widget? filter;
  final Widget child;

  /// Right-side border (useful when stacking panels side-by-side).
  final bool rightBorder;

  const AppPanel({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.titleIcon,
    this.trailing,
    this.filter,
    this.rightBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border:
            rightBorder
                ? Border(right: BorderSide(color: theme.dividerColor))
                : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: title,
            subtitle: subtitle,
            titleIcon: titleIcon,
            trailing: trailing,
          ),
          if (filter != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: filter,
            ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The header strip used by [AppPanel] and any view that wants the same
/// surface treatment without the body container.
class PanelHeader extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final IconData? titleIcon;
  final Widget? trailing;

  /// Slightly tighter vertical padding for headers that float above
  /// their own content (e.g. toolbars) vs panels that hold a column.
  final EdgeInsetsGeometry padding;

  const PanelHeader({
    super.key,
    this.title,
    this.subtitle,
    this.titleIcon,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(8, 4, 4, 4),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: padding,
      child: Row(
        children: [
          if (titleIcon != null) ...[
            Icon(titleIcon, size: 14, color: theme.colorScheme.secondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                      fontFamily: 'Menlo',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

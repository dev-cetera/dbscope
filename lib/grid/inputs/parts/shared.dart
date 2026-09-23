part of '../column_input.dart';

class _NullPlaceholder extends StatelessWidget {
  const _NullPlaceholder();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppBevel(
      raised: false,
      color: palette.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(
        children: [
          Icon(Icons.block, size: 12, color: palette.mutedText),
          const SizedBox(width: 6),
          Text(
            'NULL',
            style: TextStyle(
              color: palette.mutedText,
              fontStyle: FontStyle.italic,
              fontSize: palette.bodyFontSize,
              fontFamily: palette.uiFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}

class _NullButton extends StatelessWidget {
  final bool isNull;
  final bool enabled;
  final VoidCallback onToggle;

  const _NullButton({
    required this.isNull,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onToggle : null,
        child: AppBevel(
          raised: !isNull,
          color: isNull ? palette.accent : palette.surface,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            'NULL',
            style: TextStyle(
              color: isNull ? palette.onAccent : palette.text,
              fontSize: palette.smallFontSize,
              fontWeight: FontWeight.bold,
              fontFamily: palette.uiFontFamily,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared theme-aware frame around an interactive input child.
class _Field extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  const _Field({
    required this.child,
    required this.enabled,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppBevel(
      raised: false,
      color: enabled ? palette.field : palette.fieldDisabled,
      padding: padding,
      child: child,
    );
  }
}

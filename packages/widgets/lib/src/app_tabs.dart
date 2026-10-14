import 'package:flutter/material.dart';

import 'palette.dart';

/// One tab descriptor for [AppTabBar].
class AppTab {
  const AppTab({required this.label, required this.child, this.icon});
  final String label;
  final IconData? icon;
  final Widget child;
}

/// Horizontal tab strip. Under bevel mode tabs use raised Win95 chrome with
/// the selected tab merging into the panel below. Under flat mode tabs are
/// underline-styled (selected gets an accent underline).
class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<AppTab> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22.0,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < tabs.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 2.0),
              child: _tab(context, i, tabs[i], i == index),
            ),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, int i, AppTab tab, bool selected) {
    final palette = AppPalette.of(context);
    final label = Row(
      children: [
        if (tab.icon != null) ...[
          Icon(tab.icon, size: 12.0, color: palette.text),
          const SizedBox(width: 4.0),
        ],
        Text(
          tab.label,
          style: TextStyle(
            fontSize: palette.bodyFontSize,
            fontFamily: palette.uiFontFamily,
            color: palette.text,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ],
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(i),
      child:
          palette.isBevel
              ? _bevelTab(palette, selected: selected, child: label)
              : _flatTab(palette, selected: selected, child: label),
    );
  }

  Widget _bevelTab(
    AppPalette palette, {
    required bool selected,
    required Widget child,
  }) {
    return Container(
      height: selected ? 22 : 20,
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.bevelHighlight),
          left: BorderSide(color: palette.bevelHighlight),
          right: BorderSide(color: palette.borderStrong),
          bottom: BorderSide(
            color: selected ? palette.surface : palette.borderStrong,
          ),
        ),
      ),
      child: Center(child: child),
    );
  }

  Widget _flatTab(
    AppPalette palette, {
    required bool selected,
    required Widget child,
  }) {
    return Container(
      height: 22.0,
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(
            color: selected ? palette.accent : Colors.transparent,
            width: 2.0,
          ),
        ),
      ),
      child: Center(child: child),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../shell/app_state.dart';

/// Layout helper: a result grid on the left + a resizable inspector
/// panel on the right. Inspector visibility tracks the global
/// [AppState.propertyInspectorCollapsed] toggle, so a Hide/Show action
/// from any tab affects every tab.
class GridWithInspector extends StatelessWidget {
  final Widget grid;
  final Widget inspector;

  const GridWithInspector({
    super.key,
    required this.grid,
    required this.inspector,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppState.instance;
    if (appState.propertyInspectorCollapsed) return grid;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: grid),
        Resizable(
          width: appState.propertyInspectorWidth,
          minWidth: 220,
          maxWidth: 700,
          side: ResizeSide.left,
          onResized: appState.setPropertyInspectorWidth,
          child: inspector,
        ),
      ],
    );
  }
}

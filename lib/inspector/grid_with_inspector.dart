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
    // The Row and the Expanded stay in the tree whether or not the
    // inspector is showing. Returning `grid` bare when collapsed would
    // swap this slot's widget type on every toggle, which unmounts the
    // grid / canvas subtree and throws away its State — see the note on
    // `_mainAreaKey` in app.dart.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: grid),
        if (!appState.propertyInspectorCollapsed)
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

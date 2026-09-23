// Contract: showing or hiding a side pane must RE-PARENT the tab
// subtree, never rebuild it.
//
// The bug this pins down: a pane wrapper that returns its child bare in
// one branch and wraps it in a Row in the other changes the widget type
// occupying that slot. `Widget.canUpdate` then returns false, Flutter
// unmounts the whole subtree and inflates a fresh one, and every State
// below is destroyed. For the Schema viewer that resets
// `_SchemaCanvasState._autoFitDone`, so the next build re-runs the
// one-shot auto-fit and overwrites the user's pan AND zoom — the cards
// visibly jump and re-centre on every sidebar / inspector toggle. The
// Linked canvas loses its per-node auto-width bookkeeping the same way.
//
// The second test documents WHY the first one matters: auto-fit is
// once-per-State by design, so a remount is always a re-fit.
//
// The third covers the other half of "the cards moved": `pan` is
// canvas-local, so a pane opening to the LEFT slides the whole diagram
// sideways with the viewport's edge unless the canvas compensates.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schema_viewer/schema_viewer.dart';

import 'package:dbscope/inspector/grid_with_inspector.dart';
import 'package:dbscope/shell/app_state.dart';

/// Stand-in for a canvas: counts how many times its State was created.
class _StateProbe extends StatefulWidget {
  const _StateProbe();
  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  static int mounts = 0;

  @override
  void initState() {
    super.initState();
    mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 900, height: 600, child: child),
    ),
  );
}

void main() {
  testWidgets('toggling the property inspector does not remount the grid', (
    tester,
  ) async {
    _StateProbeState.mounts = 0;
    final appState = AppState.instance;
    if (appState.propertyInspectorCollapsed) appState.togglePropertyInspector();

    // Deliberately NOT const: a const widget is identical across pumps,
    // so Flutter skips the rebuild and the branch under test never runs
    // — the test would then pass even with the bug present.
    Widget build() => _host(
      // ignore: prefer_const_constructors
      GridWithInspector(
        grid: const _StateProbe(),
        inspector: const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(build());
    final first = tester.state(find.byType(_StateProbe));
    expect(_StateProbeState.mounts, 1, reason: 'initial mount');

    // Hide the inspector.
    appState.togglePropertyInspector();
    await tester.pumpWidget(build());
    expect(
      _StateProbeState.mounts,
      1,
      reason: 'hiding the inspector must not rebuild the grid subtree',
    );
    expect(tester.state(find.byType(_StateProbe)), same(first));

    // Show it again.
    appState.togglePropertyInspector();
    await tester.pumpWidget(build());
    expect(
      _StateProbeState.mounts,
      1,
      reason: 'showing the inspector must not rebuild the grid subtree',
    );
    expect(tester.state(find.byType(_StateProbe)), same(first));
  });

  testWidgets('SchemaCanvas auto-fit is once per State, so a remount re-fits', (
    tester,
  ) async {
    final nodes = [
      SchemaNodeData(
        id: 'public.a',
        schema: 'public',
        tableName: 'a',
        fields: const [SchemaFieldSpec(name: 'id', typeLabel: 'int', pk: true)],
        position: const Offset(0, 0),
      ),
      SchemaNodeData(
        id: 'public.b',
        schema: 'public',
        tableName: 'b',
        fields: const [SchemaFieldSpec(name: 'id', typeLabel: 'int', pk: true)],
        position: const Offset(600, 400),
      ),
    ];

    var fits = 0;
    var pan = Offset.zero;
    var scale = 1.0;

    Widget build({required Key key}) => _host(
      SchemaCanvas(
        key: key,
        nodes: nodes,
        edges: const [],
        pan: pan,
        scale: scale,
        onPanChanged: (p) {
          pan = p;
          fits++;
        },
        onScaleChanged: (s) => scale = s,
        selectedId: null,
        onSelectedChanged: (_) {},
      ),
    );

    await tester.pumpWidget(build(key: const ValueKey('canvas')));
    await tester.pump();
    expect(fits, 1, reason: 'auto-fit fires once on first layout');

    // A plain rebuild (same State) must not re-fit.
    await tester.pumpWidget(build(key: const ValueKey('canvas')));
    await tester.pump();
    expect(fits, 1, reason: 'rebuilding with the same State must not re-fit');

    // A remount re-fits and overwrites pan/scale — this is exactly what a
    // pane toggle used to do, and why the wrappers keep a stable shape.
    await tester.pumpWidget(build(key: const ValueKey('canvas-remounted')));
    await tester.pump();
    expect(fits, 2, reason: 'a fresh State re-runs auto-fit');
  });

  testWidgets('a pane opening on the left does not move the cards on screen', (
    tester,
  ) async {
    final nodes = [
      SchemaNodeData(
        id: 'public.a',
        schema: 'public',
        tableName: 'a',
        fields: const [SchemaFieldSpec(name: 'id', typeLabel: 'int', pk: true)],
        position: const Offset(40, 40),
      ),
    ];

    var paneOpen = false;
    var pan = Offset.zero;
    late StateSetter setOuter;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return Row(
                  children: [
                    if (paneOpen) const SizedBox(width: 250),
                    Expanded(
                      child: SchemaCanvas(
                        nodes: nodes,
                        edges: const [],
                        pan: pan,
                        scale: 1.0,
                        // Off so the assertion is about anchoring alone.
                        autoFitOnFirstLayout: false,
                        onPanChanged: (p) => setState(() => pan = p),
                        onScaleChanged: (_) {},
                        selectedId: null,
                        onSelectedChanged: (_) {},
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    const frame = Duration(milliseconds: 16);
    await tester.pump(frame);
    await tester.pump(frame);
    final card = find.byType(SchemaCard).first;
    final before = tester.getTopLeft(card);

    setOuter(() => paneOpen = true);
    // The correction costs exactly one frame (measured): the ticker runs
    // in the animation phase, before layout, so the frame that opens the
    // pane still paints at the old pan and the next one is correct.
    await tester.pump(frame);
    await tester.pump(frame);

    expect(
      tester.getTopLeft(card),
      before,
      reason: 'opening a 250px left pane must not drag the diagram with it',
    );
    expect(pan.dx, -250.0, reason: 'pan absorbed the viewport origin shift');

    // ...and closing it puts the pan back.
    setOuter(() => paneOpen = false);
    await tester.pump(frame);
    await tester.pump(frame);
    await tester.pump(frame);

    expect(tester.getTopLeft(card), before);
    expect(pan.dx, 0.0);
  });
}

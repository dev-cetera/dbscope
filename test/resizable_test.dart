// Contract: a resize handle follows every pointer delta live, and
// reports the accumulated size to its parent once, when the drag ends.
// Reporting each move made every caller notify the whole window, which
// rebuilt the shell on every frame of a drag.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgets/widgets.dart';

void main() {
  testWidgets('horizontal resize follows the drag and reports once at the end', (
    tester,
  ) async {
    final widths = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Resizable(
            width: 100.0,
            onResized: widths.add,
            child: const SizedBox(),
          ),
        ),
      ),
    );

    final rect = tester.getRect(find.byType(Resizable));
    final gesture = await tester.startGesture(
      Offset(rect.right - 2.0, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(10.0, 0.0));
    await gesture.moveBy(const Offset(10.0, 0.0));
    await tester.pump();

    expect(tester.getSize(find.byType(Resizable)).width, 130.0);
    expect(widths, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(widths, <double>[130.0]);
  });

  testWidgets('vertical resize follows the drag and reports once at the end', (
    tester,
  ) async {
    final heights = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200.0,
            child: VResizable(
              height: 100.0,
              onResized: heights.add,
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    );

    final rect = tester.getRect(find.byType(VResizable));
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.bottom - 2.0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0.0, 10.0));
    await gesture.moveBy(const Offset(0.0, 10.0));
    await tester.pump();

    final liveHeight = tester.getSize(find.byType(VResizable)).height;
    expect(liveHeight, greaterThan(100.0));
    expect(heights, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(heights, <double>[liveHeight]);
  });
}

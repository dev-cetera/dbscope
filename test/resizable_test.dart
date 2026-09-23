import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgets/widgets.dart';

void main() {
  testWidgets('horizontal resize accumulates every pointer delta', (
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
    await gesture.up();

    expect(widths, <double>[120.0, 130.0]);
  });

  testWidgets('vertical resize accumulates every pointer delta', (
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
    await gesture.up();

    expect(heights.last, 120.0);
  });
}

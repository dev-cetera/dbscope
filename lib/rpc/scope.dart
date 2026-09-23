// BackendScope — InheritedWidget that exposes the per-window
// BackendClient. Widgets call BackendScope.of(context) to talk to the
// server without caring whether they're in the host or a subwindow.

import 'package:flutter/widgets.dart';

import 'backend_client.dart';

class BackendScope extends InheritedWidget {
  final BackendClient client;

  const BackendScope({
    super.key,
    required this.client,
    required super.child,
  });

  static BackendClient of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BackendScope>();
    assert(scope != null, 'No BackendScope in widget tree');
    return scope!.client;
  }

  static BackendClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendScope>()?.client;

  @override
  bool updateShouldNotify(BackendScope oldWidget) => oldWidget.client != client;
}

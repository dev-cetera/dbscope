import 'package:flutter/widgets.dart';

/// Subscribes to one or more [Listenable]s for the lifetime of a
/// [State], calling [setState] whenever any of them notify. Replaces
/// the boilerplate triplet of:
///
/// ```dart
/// @override
/// void initState() {
/// super.initState();
/// Singleton.instance.addListener(_onChange);
/// }
///
/// @override
/// void dispose() {
/// Singleton.instance.removeListener(_onChange);
/// super.dispose();
/// }
///
/// void _onChange() {
/// if (mounted) setState(() {});
/// }
/// ```
///
/// Usage:
///
/// ```dart
/// class _MyState extends State<_My> with ListenableStateMixin {
/// @override
/// List<Listenable> get listenables => [
/// AppState.instance,
/// ConnectionRegistry.instance,
/// ];
/// }
/// ```
mixin ListenableStateMixin<T extends StatefulWidget> on State<T> {
  /// Listenables to subscribe to. Re-evaluated only at [initState]; if
  /// the set changes over time, override [didUpdateWidget] to manage
  /// the subscription yourself.
  List<Listenable> get listenables;

  @override
  void initState() {
    super.initState();
    for (final listenable in listenables) {
      listenable.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    for (final listenable in listenables) {
      listenable.removeListener(_onChange);
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }
}

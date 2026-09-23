import 'package:flutter/material.dart';

import 'states.dart';

/// State-machine mixin for the "load once, render loading/error/data"
/// pattern that repeats across most StatefulWidgets in the app.
///
/// Subclasses implement [loadData] and the [build] method calls
/// [buildAsync] to render the current state. The mixin guards against
/// setState-after-dispose and supports re-load via [reload].
///
/// ```dart
/// class _MyPaneState extends State<MyPane> with AsyncLoaderMixin<MyPane, List<Row>> {
/// @override
/// Future<List<Row>> loadData() => api.fetchRows();
///
/// @override
/// Widget build(BuildContext context) {
/// return buildAsync(
/// data: (rows) => _list(rows),
/// );
/// }
/// }
/// ```
mixin AsyncLoaderMixin<W extends StatefulWidget, T> on State<W> {
  T? _data;
  Object? _error;
  bool _loading = true;
  int _loadId = 0;

  T? get data => _data;
  Object? get error => _error;
  bool get isLoading => _loading;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Subclass hook. Called from [initState] and [reload].
  Future<T> loadData();

  /// Discards any in-flight load (via a generation counter) and starts
  /// a new one. Safe to call from event handlers; multiple rapid
  /// invocations only honor the latest.
  Future<void> reload() async {
    final myId = ++_loadId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await loadData();
      if (!mounted || myId != _loadId) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || myId != _loadId) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Renders the current load state. By default loading shows
  /// [LoadingView], errors show [ErrorView] with a retry that calls
  /// [reload], and data delegates to the [data] builder. Override
  /// [loadingBuilder] / [errorBuilder] only when the defaults are
  /// wrong for a specific call site.
  Widget buildAsync({
    required Widget Function(T data) data,
    Widget Function(BuildContext context)? loadingBuilder,
    Widget Function(BuildContext context, Object error)? errorBuilder,
  }) {
    if (_loading) {
      return loadingBuilder?.call(context) ?? const LoadingView();
    }
    if (_error != null) {
      return errorBuilder?.call(context, _error!) ??
          ErrorView(message: _error.toString(), onRetry: reload);
    }
    final value = _data;
    if (value == null) {
      // loadData returned null in an `Future<T?>` subclass; treat as
      // "nothing loaded" and stay on loading visuals.
      return loadingBuilder?.call(context) ?? const LoadingView();
    }
    return data(value);
  }
}

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../ai/regex_inferrer.dart';
import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../db/dml.dart';
import '../db/edit_policy.dart';
import '../grid/row_dialog.dart';
import '../inspector/property_inspector.dart';
import '../query/pager.dart';
import '../shell/app_state.dart';
import '../util/pg_errors.dart';
import '../util/sql_quote.dart';
import 'navigator_tab.dart';

part 'parts/table_list_column.dart';
part 'parts/row_list_column.dart';
part 'parts/row_detail_column.dart';

const double _kTableListWidth = 260;
const double _kRowDetailWidth = 360;
const double _kRowListMinWidth = 340;
const int _kPageSize = 500;

class NavigatorTabView extends StatefulWidget {
  final NavigatorTab tab;
  const NavigatorTabView({super.key, required this.tab});

  @override
  State<NavigatorTabView> createState() => _NavigatorTabViewState();
}

class _NavigatorTabViewState extends State<NavigatorTabView> {
  final _hScroll = ScrollController();
  String? _lastTrailingStepId;

  @override
  void initState() {
    super.initState();
    _lastTrailingStepId = widget.tab.steps.isEmpty
        ? null
        : widget.tab.steps.last.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadFKsIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant NavigatorTabView old) {
    super.didUpdateWidget(old);
    final currentTrailing = widget.tab.steps.isEmpty
        ? null
        : widget.tab.steps.last.id;
    if (currentTrailing != _lastTrailingStepId) {
      // Trailing column changed (path grew OR a prior column was clicked
      // and replaced what comes after) — scroll the new rightmost into
      // view. Target the "natural rightmost" position rather than
      // maxScrollExtent so we don't slide into the right over-scroll pad
      // (where the rightmost column would be flush-left with the rest of
      // the viewport blank).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_hScroll.hasClients) return;
        final natural = _naturalRightmostScroll;
        if (natural == null) return;
        _hScroll.animateTo(
          natural,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
    }
    _lastTrailingStepId = currentTrailing;
  }

  /// Cached per-build: the scroll offset at which the rightmost step's
  /// right edge sits flush with the viewport's right edge (no
  /// over-scroll). Re-set inside the LayoutBuilder so the math always
  /// reflects the current viewport + widths. Null until first build.
  double? _naturalRightmostScroll;

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  Future<void> _loadFKsIfNeeded() async {
    if (widget.tab.fksLoaded) return;
    final conn = ConnectionRegistry.instance.connectionFor(
      widget.tab.connectionId,
    );
    if (conn == null) {
      widget.tab.fksError = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    try {
      final fks = await SchemaCatalog(conn).listForeignKeys();
      widget.tab.foreignKeys = fks;
      widget.tab.fksLoaded = true;
      widget.tab.fksError = null;
    } catch (e) {
      widget.tab.fksError = classify(e).message;
    }
    if (mounted) AppState.instance.notifyChange();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tab = widget.tab;
    if (tab.steps.isEmpty) {
      return Container(
        color: theme.colorScheme.surfaceContainerLow,
        child: const EmptyState(
          icon: Icons.view_column_outlined,
          message: 'Pick a table from the sidebar to start exploring.',
        ),
      );
    }
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final widths = _computeWidths(tab.steps);
          final viewport = constraints.maxWidth;
          // Finder-style bounded over-scroll: pad both sides so the user
          // can scroll past the natural bounds, capped so at least the
          // first/last column is always visible. The leftmost column's
          // right edge can reach the viewport's right edge; the rightmost
          // column's left edge can reach the viewport's left edge.
          final leftmostW = widths.first;
          final rightmostW = widths.last;
          final leftPad = math.max(0.0, viewport - leftmostW);
          final rightPad = math.max(0.0, viewport - rightmostW);
          final sumWidths = widths.fold<double>(0, (a, b) => a + b);
          _naturalRightmostScroll = math.max(
            0.0,
            leftPad + sumWidths - viewport,
          );

          return Scrollbar(
            controller: _hScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                height: constraints.maxHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: leftPad),
                    for (var i = 0; i < tab.steps.length; i++)
                      Resizable(
                        width: widths[i],
                        minWidth: _minWidth(tab.steps[i]),
                        maxWidth: 1600,
                        onResized: (w) {
                          tab.setStepWidth(tab.steps[i].id, w);
                          AppState.instance.notifyChange();
                        },
                        child: _widgetFor(tab.steps[i], i),
                      ),
                    SizedBox(width: rightPad),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Width per column. User overrides via the resize handle win;
  /// otherwise every step uses its default width. The trailing column
  /// no longer expands to fill the viewport — that pushed the chevrons
  /// far from the row text and looked broken on wide screens.
  List<double> _computeWidths(List<NavStep> steps) {
    return [
      for (final s in steps) widget.tab.stepWidths[s.id] ?? _defaultWidth(s),
    ];
  }

  double _defaultWidth(NavStep step) {
    if (step is TableListStep) return _kTableListWidth;
    if (step is RowListStep) return _kRowListMinWidth;
    if (step is RowDetailStep) return _kRowDetailWidth;
    return _kRowDetailWidth;
  }

  double _minWidth(NavStep step) {
    if (step is TableListStep) return 160;
    if (step is RowListStep) return 330;
    return 220;
  }

  Widget _widgetFor(NavStep step, int index) {
    return switch (step) {
      TableListStep _ => TableListColumn(tab: widget.tab, index: index),
      RowListStep s => RowListColumn(tab: widget.tab, index: index, step: s),
      RowDetailStep s => RowDetailColumn(
        tab: widget.tab,
        index: index,
        step: s,
      ),
    };
  }
}

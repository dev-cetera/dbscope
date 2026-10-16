import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cell_editor.dart';
import 'cell_overlay.dart';
import 'cell_range.dart';
import 'cell_renderer.dart';
import 'grid_data.dart';
import 'grid_model.dart';
import 'grid_style.dart';
import 'internal/grid_header.dart';
import 'internal/grid_row.dart';
import 'serialize.dart';

const double _kDefaultHeaderHeight = 44;
const double _kGutterWidth = 52;
const double _kResizeHotZone = 6;

/// Drives incremental updates to a [DataGrid] without rebuilding the
/// entire row set. Owned by the caller and passed to the grid widget.
///
/// Rebuilding the row list on every page append would be O(N) per
/// page, so scrolling N pages would be O(N²). With a controller,
/// [appendRows] is O(delta) per page and [removeFirstRows] enforces a
/// bounded in-memory window so scrolling a billion-row table does not
/// OOM.
class DataGridController<TypeTag> {
  _DataGridState<TypeTag>? _state;

  // Paired with `_detach`; a setter would hide that lifecycle pairing.
  // ignore: use_setters_to_change_properties
  void _attach(_DataGridState<TypeTag> state) => _state = state;
  void _detach(_DataGridState<TypeTag> state) {
    if (identical(_state, state)) _state = null;
  }

  void replaceAll(GridData<TypeTag> data) => _state?._applyReplaceAll(data);
  void appendRows(List<List<Object?>> rows) => _state?._applyAppend(rows);
  void removeFirstRows(int count) => _state?._applyRemoveFirst(count);
  void removeRowAt(int index) => _state?._applyRemoveAt(index);
  void prependRow(List<Object?> row) => _state?._applyPrepend(row);
  void updateCell(int rowIdx, String column, Object? value) =>
      _state?._applyUpdateCell(rowIdx, column, value);

  /// Hide exactly [names] (every other column is shown).
  void setHiddenColumns(Set<String> names) => _state?._applySetHidden(names);

  /// Set an explicit height for a single row. Pass `null` to clear the
  /// override and fall back to the grid's default `rowHeight`.
  void setRowHeight(int rowIdx, double? height) =>
      _state?._applySetRowHeight(rowIdx, height);

  /// Drop all per-row overrides so every row reverts to the default
  /// `rowHeight`.
  void clearRowHeights() => _state?._applyClearRowHeights();

  /// Current effective height for [rowIdx] (override if present, else the
  /// default `rowHeight`).
  double? rowHeightOf(int rowIdx) => _state?._heightFor(rowIdx);

  bool get isAttached => _state != null;
}

/// Hand-rolled high-performance data grid. See package README for
/// the full feature set; the short version: drag-range selection,
/// column reorder/resize, pluggable cell renderers + editors,
/// TSV/CSV copy, imperative controller, billion-row-friendly.
class DataGrid<TypeTag> extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.data,
    this.isLoading = false,
    this.error,
    this.controller,
    this.cellRenderer,
    this.cellEditor,
    this.cellOverlay,
    this.style,
    this.rowHeight,
    this.onRowHeightChanged,
    this.headerHeight = _kDefaultHeaderHeight,
    this.defaultColumnWidth = 220,
    this.onLoadMore,
    this.hasMore = false,
    this.onCellEdit,
    this.onSort,
    this.onDeleteRow,
    this.onOpenDetail,
    this.onRowSelected,
    this.showGutter = true,
    this.contextMenuExtras,
    this.headerBuilder,
  });

  /// Initial data set. After mount, prefer pushing changes through
  /// [controller] — when a controller is attached the widget ignores
  /// later identity changes on [data].
  final GridData<TypeTag> data;

  /// Show a non-blocking loading overlay (e.g. while fetching more
  /// rows).
  final bool isLoading;

  /// Replace the grid body with a full-area error surface.
  final String? error;

  /// Optional controller for incremental updates.
  final DataGridController<TypeTag>? controller;

  /// Pluggable cell renderer. Defaults to [DefaultCellRenderer].
  final CellRenderer<TypeTag>? cellRenderer;

  /// Pluggable cell editor. Null = grid is read-only.
  final CellEditor<TypeTag>? cellEditor;

  /// Optional overlay painter (e.g. link badges).
  final CellOverlayProvider<TypeTag>? cellOverlay;

  /// Optional explicit style. Defaults to one derived from the
  /// material [ThemeData].
  final GridStyle? style;

  /// Row-height state. Pass a `ValueNotifier<double>` so the grid
  /// rebuilds when an external slider drags it. Defaults to a fixed
  /// 32 px row.
  final ValueListenable<double>? rowHeight;

  /// Notification: called after the user drags the row-resize hot-zone
  /// on a specific row. The grid has already updated the per-row
  /// override internally; this callback exists so the host can persist
  /// or react to the change.
  final void Function(int rowIdx, double newHeight)? onRowHeightChanged;

  /// Header row height. Default 44.
  final double headerHeight;

  /// Width used for columns without an explicit `defaultWidth`.
  final double defaultColumnWidth;

  /// Pagination hook — called when the user scrolls near the
  /// bottom. Returns synchronously; if the caller is fetching more
  /// rows it should set [isLoading] until the page arrives.
  final VoidCallback? onLoadMore;
  final bool hasMore;

  /// Fired when a cell commit produces a new value.
  final void Function(GridEditEvent event)? onCellEdit;

  /// Fired when a header click flips sort.
  final void Function(GridSortEvent event)? onSort;

  /// Optional row-level context-menu hooks.
  final void Function(int rowIdx)? onDeleteRow;
  final void Function(int rowIdx)? onOpenDetail;

  /// Fires whenever the focus row changes (including null when the
  /// selection clears). Use this to drive a side-detail panel.
  final void Function(int? rowIdx)? onRowSelected;

  /// Show the row-number gutter. Disable for compact grids.
  final bool showGutter;

  /// Extra right-click entries for the clicked cell, by row index,
  /// ORIGINAL column index (into `data.columns`) and the selected rows. A right-click outside the
  /// current selection first moves the selection to the clicked cell, so
  /// entries always act on what the user pointed at.
  final List<GridMenuEntry> Function(
    int rowIdx,
    int columnIdx,
    List<int> selectedRows,
  )? contextMenuExtras;

  /// Wraps each column header (ORIGINAL column index) — e.g. a rich
  /// description tooltip and a right-click menu. Null shows the column's
  /// plain [GridColumnSpec.tooltip], if any, over the whole header.
  final Widget Function(BuildContext context, int columnIdx, Widget header)?
      headerBuilder;

  @override
  State<DataGrid<TypeTag>> createState() => _DataGridState<TypeTag>();
}

class _DataGridState<TypeTag> extends State<DataGrid<TypeTag>> {
  /// The grid's own row list. Never the caller's: a controller-driven
  /// caller keeps its buffer in sync by applying the same mutation
  /// itself and then calling [DataGridController.appendRows] etc., so
  /// sharing one list would apply every append / trim / delete / insert
  /// twice. Copying is O(rows) once per [_applyReplaceAll]; the row
  /// lists themselves stay shared, so [_applyUpdateCell] still writes
  /// through to the caller's row.
  late GridData<TypeTag> _currentData;

  static GridData<T> _ownCopy<T>(GridData<T> data) =>
      GridData<T>(columns: data.columns, rows: List.of(data.rows));
  final _model = GridModel();
  final _vScroll = ScrollController();
  final _hScroll = ScrollController();
  final _gridFocus = FocusNode(debugLabel: 'DataGrid');
  final _gutterScroll = ScrollController();
  late final _fallbackRowHeight = ValueNotifier<double>(_kDefaultRowHeight);
  String? _sortColumn;
  var _sortDescending = false;
  int? _lastReportedRowIdx;
  var _syncingScroll = false;
  var _isDragging = false;

  ValueListenable<double> get _rowHeightListenable =>
      widget.rowHeight ?? _fallbackRowHeight;
  double get _rowHeight => _rowHeightListenable.value;

  /// Per-row height overrides, keyed by row index. Lost on data
  /// replace; shifted when rows are inserted/removed at the top.
  final Map<int, double> _rowHeightOverrides = {};

  /// Effective height for the row at [rowIndex]: override if set,
  /// otherwise the default `rowHeight`.
  double _heightFor(int rowIndex) =>
      _rowHeightOverrides[rowIndex] ?? _rowHeight;

  /// Row height used when the host supplies no `rowHeight` notifier.
  static const double _kDefaultRowHeight = 32;
  static const double _kMinRowHeight = 12;
  static const double _kMaxRowHeight = 1200;

  CellRenderer<TypeTag> get _renderer =>
      // Typed explicitly: a bare `const DefaultCellRenderer()` here infers
      // its own type argument, not TypeTag, and fails a cast while painting.
      widget.cellRenderer ?? DefaultCellRenderer<TypeTag>();

  @override
  void initState() {
    super.initState();
    _currentData = _ownCopy(widget.data);
    _initModel();
    _model.addListener(_onModelChange);
    _rowHeightListenable.addListener(_onRowHeightChanged);
    _vScroll.addListener(_onVScroll);
    _vScroll.addListener(_syncGutterFromMain);
    _gutterScroll.addListener(_syncMainFromGutter);
    widget.controller?._attach(this);
  }

  void _onRowHeightChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _syncGutterFromMain() {
    if (_syncingScroll) return;
    if (!_gutterScroll.hasClients) return;
    if (_gutterScroll.offset == _vScroll.offset) return;
    _syncingScroll = true;
    _gutterScroll.jumpTo(
      _vScroll.offset.clamp(0.0, _gutterScroll.position.maxScrollExtent),
    );
    _syncingScroll = false;
  }

  void _syncMainFromGutter() {
    if (_syncingScroll) return;
    if (!_vScroll.hasClients) return;
    if (_vScroll.offset == _gutterScroll.offset) return;
    _syncingScroll = true;
    _vScroll.jumpTo(
      _gutterScroll.offset.clamp(0.0, _vScroll.position.maxScrollExtent),
    );
    _syncingScroll = false;
  }

  void _initModel() {
    _model.resetColumns(
      _currentData.columns.length,
      [
        for (final column in _currentData.columns)
          column.defaultWidth ?? widget.defaultColumnWidth,
      ],
      hidden: {
        for (var i = 0; i < _currentData.columns.length; i++)
          if (_currentData.columns[i].hidden) i,
      },
    );
    _model.setRowCount(_currentData.rows.length);
  }

  @override
  void didUpdateWidget(covariant DataGrid<TypeTag> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    final oldListenable = oldWidget.rowHeight ?? _fallbackRowHeight;
    final newListenable = widget.rowHeight ?? _fallbackRowHeight;
    if (!identical(oldListenable, newListenable)) {
      oldListenable.removeListener(_onRowHeightChanged);
      newListenable.addListener(_onRowHeightChanged);
    }
    if (widget.controller == null && !identical(oldWidget.data, widget.data)) {
      _applyReplaceAll(widget.data);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _model.removeListener(_onModelChange);
    _model.dispose();
    _rowHeightListenable.removeListener(_onRowHeightChanged);
    _fallbackRowHeight.dispose();
    _vScroll.removeListener(_onVScroll);
    _vScroll.removeListener(_syncGutterFromMain);
    _vScroll.dispose();
    _gutterScroll.removeListener(_syncMainFromGutter);
    _gutterScroll.dispose();
    _hScroll.dispose();
    _gridFocus.dispose();
    super.dispose();
  }

  void _onModelChange() {
    if (!mounted) return;
    setState(() {});
    final selection = _model.selection;
    final index = selection?.focusRow;
    if (index != _lastReportedRowIdx) {
      _lastReportedRowIdx = index;
      widget.onRowSelected?.call(index);
    }
  }

  void _onVScroll() {
    if (widget.onLoadMore == null || !widget.hasMore || widget.isLoading) {
      return;
    }
    final position = _vScroll.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      widget.onLoadMore!();
    }
  }

  // --- Controller hooks --------------------------------------------------

  void _applyReplaceAll(GridData<TypeTag> data) {
    _currentData = _ownCopy(data);
    _rowHeightOverrides.clear();
    _initModel();
    if (mounted) setState(() {});
  }

  void _applySetHidden(Set<String> names) {
    _model.setHidden({
      for (var i = 0; i < _currentData.columns.length; i++)
        if (names.contains(_currentData.columns[i].name)) i,
    });
  }

  void _applyAppend(List<List<Object?>> rows) {
    if (rows.isEmpty) return;
    _currentData.rows.addAll(rows);
    _model.setRowCount(_currentData.rows.length);
  }

  void _applyRemoveFirst(int count) {
    final actual = count.clamp(0, _currentData.rows.length);
    if (actual == 0) return;
    // Scroll compensation must use the actual extents of the trimmed
    // rows (some may be taller/shorter than the default).
    var removedExtent = 0.0;
    for (var i = 0; i < actual; i++) {
      removedExtent += _heightFor(i);
    }
    _shiftOverrides(-actual);
    _currentData.rows.removeRange(0, actual);
    final scroll = _vScroll;
    if (scroll.hasClients) {
      final previous = scroll.position.pixels;
      final target = (previous - removedExtent)
          .clamp(0.0, scroll.position.maxScrollExtent);
      if (target != previous) scroll.jumpTo(target);
    }
    _model.rowsRemoved(0, actual);
  }

  void _applyRemoveAt(int index) {
    if (index < 0 || index >= _currentData.rows.length) return;
    _currentData.rows.removeAt(index);
    _shiftOverridesFrom(index, -1);
    _model.rowsRemoved(index, 1);
  }

  void _applyPrepend(List<Object?> row) {
    _currentData.rows.insert(0, row);
    _shiftOverrides(1);
    _model.rowsInserted(0, 1);
  }

  /// Shift every override index by [delta]; entries that would fall to
  /// a negative index after the shift are dropped (they belong to rows
  /// that no longer exist).
  void _shiftOverrides(int delta) {
    if (_rowHeightOverrides.isEmpty || delta == 0) return;
    final shifted = <int, double>{};
    for (final e in _rowHeightOverrides.entries) {
      final ni = e.key + delta;
      if (ni >= 0) shifted[ni] = e.value;
    }
    _rowHeightOverrides
      ..clear()
      ..addAll(shifted);
  }

  /// Shift overrides at or above [from] by [delta] (used for
  /// remove/insert at a specific index).
  void _shiftOverridesFrom(int from, int delta) {
    if (_rowHeightOverrides.isEmpty || delta == 0) return;
    final shifted = <int, double>{};
    for (final e in _rowHeightOverrides.entries) {
      if (e.key < from) {
        shifted[e.key] = e.value;
      } else if (e.key == from && delta < 0) {
        // The row at `from` is being removed — drop its override.
      } else {
        final ni = e.key + delta;
        if (ni >= 0) shifted[ni] = e.value;
      }
    }
    _rowHeightOverrides
      ..clear()
      ..addAll(shifted);
  }

  void _applySetRowHeight(int rowIndex, double? height) {
    if (rowIndex < 0 || rowIndex >= _currentData.rows.length) return;
    if (height == null) {
      if (_rowHeightOverrides.remove(rowIndex) != null && mounted) {
        setState(() {});
      }
      return;
    }
    final clamped = height.clamp(_kMinRowHeight, _kMaxRowHeight);
    if (_rowHeightOverrides[rowIndex] == clamped) return;
    _rowHeightOverrides[rowIndex] = clamped;
    if (mounted) setState(() {});
  }

  void _applyClearRowHeights() {
    if (_rowHeightOverrides.isEmpty) return;
    _rowHeightOverrides.clear();
    if (mounted) setState(() {});
  }

  void _onGutterResize(int rowIndex, double delta) {
    final current = _heightFor(rowIndex);
    final next = (current + delta).clamp(_kMinRowHeight, _kMaxRowHeight);
    _applySetRowHeight(rowIndex, next);
    widget.onRowHeightChanged?.call(rowIndex, next);
  }

  void _applyUpdateCell(int rowIndex, String column, Object? value) {
    if (rowIndex < 0 || rowIndex >= _currentData.rows.length) return;
    final columnIndex = _currentData.columns.indexWhere(
      (spec) => spec.name == column,
    );
    if (columnIndex < 0) return;
    _currentData.rows[rowIndex][columnIndex] = value;
    if (mounted) setState(() {});
  }

  // --- Sort / reorder / resize ------------------------------------------

  void _onSortToggle(int originalIndex) {
    if (widget.onSort == null) return;
    final column = _currentData.columns[originalIndex];
    final descending = _sortColumn == column.name && !_sortDescending;
    setState(() {
      _sortColumn = column.name;
      _sortDescending = descending;
    });
    widget.onSort!(GridSortEvent(column.name, descending: descending));
  }

  void _onWidthChanged(int originalIndex, double width) =>
      _model.setColumnWidth(originalIndex, width);

  void _onReorder(int fromView, int toView) =>
      _model.reorderColumn(fromView, toView);

  // --- Cell interaction --------------------------------------------------

  void _onCellTap(int row, int column, {required bool extend}) {
    if (extend) {
      _model.extendSelection(row, column);
    } else {
      _model.selectSingle(row, column);
    }
    _gridFocus.requestFocus();
  }

  void _onCellDoubleTap(int row, int column) {
    final editor = widget.cellEditor;
    if (editor == null) return;
    final originalIndex = _model.viewToOriginal(column);
    final spec = _currentData.columns[originalIndex];
    if (!editor.canEdit(spec)) return;
    if (widget.onCellEdit == null) return;
    if (editor.requiresDialog(spec)) {
      unawaited(_editViaDialog(row, originalIndex, spec));
      return;
    }
    _model.beginEdit(row, column);
  }

  Future<void> _editViaDialog(
    int row,
    int originalIndex,
    GridColumnSpec<TypeTag> spec,
  ) async {
    final editor = widget.cellEditor!;
    final oldValue = _currentData.rows[row][originalIndex];
    final result = await editor.openDialog(context, oldValue, spec);
    if (result == null) return;
    if (result == oldValue) return;
    widget.onCellEdit?.call(
      GridEditEvent(row, spec.name, oldValue, result),
    );
  }

  ({int row, int col})? _hitTest(Offset localPosition) {
    if (localPosition.dy < 0 || localPosition.dx < 0) return null;
    if (_currentData.rows.isEmpty || _model.order.isEmpty) return null;
    final vOffset = _vScroll.hasClients ? _vScroll.offset : 0.0;
    final targetY = vOffset + localPosition.dy;
    final int absRow;
    if (_rowHeightOverrides.isEmpty) {
      // Fast path: every row has the default height.
      absRow = targetY ~/ _rowHeight;
    } else {
      // Mixed heights: walk forward summing extents. In practice
      // overrides are a small map and the visible window is bounded,
      // so this is fast enough for the hit-test path.
      var acc = 0.0;
      var found = -1;
      for (var i = 0; i < _currentData.rows.length; i++) {
        final height = _heightFor(i);
        if (targetY < acc + height) {
          found = i;
          break;
        }
        acc += height;
      }
      if (found < 0) return null;
      absRow = found;
    }
    if (absRow < 0 || absRow >= _currentData.rows.length) return null;
    var acc = 0.0;
    for (var v = 0; v < _model.order.length; v++) {
      final width = _model.widthAt(v);
      if (localPosition.dx >= acc && localPosition.dx < acc + width) {
        return (row: absRow, col: v);
      }
      acc += width;
    }
    return null;
  }

  void _onBodyPointerDown(PointerDownEvent e, Offset localPosition) {
    if (e.buttons != kPrimaryButton) return;
    if (_model.isEditing) return;
    final hit = _hitTest(localPosition);
    if (hit == null) return;
    _isDragging = true;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.shift);
    if (shift && _model.selection != null) {
      _model.extendSelection(hit.row, hit.col);
    } else {
      _model.selectSingle(hit.row, hit.col);
    }
    _gridFocus.requestFocus();
  }

  void _onBodyPointerMove(PointerMoveEvent e, Offset localPosition) {
    if (!_isDragging) return;
    if (e.buttons != kPrimaryButton) {
      _isDragging = false;
      return;
    }
    final hit = _hitTest(localPosition);
    if (hit == null) return;
    _model.extendSelection(hit.row, hit.col);
  }

  void _onBodyPointerUp(PointerUpEvent e) {
    _isDragging = false;
  }

  void _onCommit(int row, int column, Object? newValue) {
    final originalIndex = _model.viewToOriginal(column);
    final spec = _currentData.columns[originalIndex];
    final oldValue = _currentData.rows[row][originalIndex];
    _model.endEdit();
    if (widget.onCellEdit == null) return;
    if (newValue == oldValue) return;
    widget.onCellEdit!(GridEditEvent(row, spec.name, oldValue, newValue));
  }

  void _onCancelEdit() => _model.endEdit();

  void _onKeyMove(int deltaRow, int deltaColumn) {
    final selection = _model.selection;
    if (selection == null) {
      if (_currentData.rows.isNotEmpty && _model.order.isNotEmpty) {
        _model.selectSingle(0, 0);
      }
      return;
    }
    final nextRow =
        (selection.focusRow + deltaRow).clamp(0, _currentData.rows.length - 1);
    final nextColumn =
        (selection.focusCol + deltaColumn).clamp(0, _model.order.length - 1);
    _model.selectSingle(nextRow, nextColumn);
  }

  Future<void> _onCopyRequest() => _copyAs(_CopyFormat.tsv);

  Future<void> _copyAs(_CopyFormat format) async {
    final selection = _model.selection;
    if (selection == null) return;
    final text = switch (format) {
      _CopyFormat.tsv => serializeRangeAsTsv(_currentData, _model, selection),
      _CopyFormat.csv => serializeRangeAsCsv(_currentData, _model, selection),
    };
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _onSelectAll() {
    if (_currentData.rows.isEmpty || _model.order.isEmpty) return;
    _model.selectSingle(0, 0);
    _model.extendSelection(
      _currentData.rows.length - 1,
      _model.order.length - 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = resolveGridStyle(context, widget.style);
    if (widget.error != null) {
      return Container(
        color: Theme.of(context).colorScheme.errorContainer,
        padding: const EdgeInsets.all(12.0),
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          child: SelectableText(
            widget.error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      );
    }
    if (_currentData.columns.isEmpty) {
      return Stack(
        children: [
          const Center(child: Text('No columns to display.')),
          if (widget.isLoading) const _LoadingOverlay(),
        ],
      );
    }
    final totalWidth = _model.totalWidth;

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft):
          const _MoveIntent(0, -1),
      const SingleActivator(LogicalKeyboardKey.arrowRight):
          const _MoveIntent(0, 1),
      const SingleActivator(LogicalKeyboardKey.arrowUp):
          const _MoveIntent(-1, 0),
      const SingleActivator(LogicalKeyboardKey.arrowDown):
          const _MoveIntent(1, 0),
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
          const _CopyIntent(),
      const SingleActivator(LogicalKeyboardKey.keyC, control: true):
          const _CopyIntent(),
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
          const _SelectAllIntent(),
      const SingleActivator(LogicalKeyboardKey.keyA, control: true):
          const _SelectAllIntent(),
      const SingleActivator(LogicalKeyboardKey.enter): const _EditIntent(),
      const SingleActivator(LogicalKeyboardKey.f2): const _EditIntent(),
    };
    final actions = <Type, Action<Intent>>{
      _MoveIntent: CallbackAction<_MoveIntent>(
        onInvoke: (intent) {
          if (!_model.isEditing) {
            _onKeyMove(intent.deltaRow, intent.deltaColumn);
          }
          return null;
        },
      ),
      _CopyIntent: CallbackAction<_CopyIntent>(
        onInvoke: (_) {
          if (!_model.isEditing) unawaited(_onCopyRequest());
          return null;
        },
      ),
      _SelectAllIntent: CallbackAction<_SelectAllIntent>(
        onInvoke: (_) {
          if (!_model.isEditing) _onSelectAll();
          return null;
        },
      ),
      _EditIntent: CallbackAction<_EditIntent>(
        onInvoke: (_) {
          final selection = _model.selection;
          if (selection != null && !_model.isEditing) {
            _onCellDoubleTap(selection.focusRow, selection.focusCol);
          }
          return null;
        },
      ),
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(
          focusNode: _gridFocus,
          child: _buildSurface(style, totalWidth),
        ),
      ),
    );
  }

  Widget _buildSurface(GridStyle style, double totalWidth) {
    final body = Stack(
      children: [
        Container(color: style.cellBackground),
        Scrollbar(
          controller: _hScroll,
          thumbVisibility: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GridHeader<TypeTag>(
                    data: _currentData,
                    model: _model,
                    style: style,
                    height: widget.headerHeight,
                    sortColumn: _sortColumn,
                    sortDescending: _sortDescending,
                    onSortToggle: widget.onSort == null ? null : _onSortToggle,
                    onWidthChanged: _onWidthChanged,
                    onReorder: _onReorder,
                    headerBuilder: widget.headerBuilder,
                  ),
                  Expanded(
                    child: GestureDetector(
                      onSecondaryTapDown: (details) => _showContextMenu(
                        details.globalPosition,
                        details.localPosition,
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (e) =>
                            _onBodyPointerDown(e, e.localPosition),
                        onPointerMove: (e) =>
                            _onBodyPointerMove(e, e.localPosition),
                        onPointerUp: _onBodyPointerUp,
                        child: Scrollbar(
                          controller: _vScroll,
                          thumbVisibility: true,
                          notificationPredicate: (notification) =>
                              notification.metrics.axis == Axis.vertical,
                          child: ListView.builder(
                            controller: _vScroll,
                            itemExtentBuilder: (i, _) => _heightFor(i),
                            itemCount: _currentData.rows.length,
                            itemBuilder: (_, i) {
                              return GridBodyRow<TypeTag>(
                                rowIdx: i,
                                values: _currentData.rows[i],
                                data: _currentData,
                                model: _model,
                                style: style,
                                renderer: _renderer,
                                editor: widget.cellEditor,
                                overlay: widget.cellOverlay,
                                rowHeight: _heightFor(i),
                                onCellTap: _onCellTap,
                                onCellDoubleTap: _onCellDoubleTap,
                                onCommit: _onCommit,
                                onCancelEdit: _onCancelEdit,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.isLoading) const _LoadingOverlay(),
      ],
    );

    if (!widget.showGutter) return body;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GutterColumn(
          style: style,
          headerHeight: widget.headerHeight,
          rowHeightFor: _heightFor,
          rowCount: _currentData.rows.length,
          scrollController: _gutterScroll,
          selection: _model.selection,
          onSelectRow: (row, {required extend}) {
            if (extend) {
              _model.extendSelection(row, _model.order.length - 1);
            } else {
              _model.selectSingle(row, 0);
              _model.extendSelection(row, _model.order.length - 1);
            }
            _gridFocus.requestFocus();
          },
          onRowResizeDelta: _onGutterResize,
        ),
        Expanded(child: body),
      ],
    );
  }

  Future<void> _showContextMenu(Offset position, Offset localPosition) async {
    // Act on the clicked cell: a right-click outside the current selection
    // moves the selection there first (inside it, a multi-cell selection is
    // kept so copy still covers the whole range).
    final hit = _hitTest(localPosition);
    if (hit != null) {
      final current = _model.selection;
      final inside = current != null && current.contains(hit.row, hit.col);
      if (!inside) _model.selectSingle(hit.row, hit.col);
    }
    final selection = _model.selection;
    final rowIndex = selection?.focusRow;
    final hasSel = selection != null;
    final extras = <GridMenuEntry>[];
    final builder = widget.contextMenuExtras;
    if (builder != null && hit != null) {
      final currentSelection = _model.selection;
      final selectedRows = currentSelection == null
          ? [hit.row]
          : [
              for (var r = currentSelection.rowMin;
                  r <= currentSelection.rowMax;
                  r++)
                r,
            ];
      extras.addAll(
        builder(hit.row, _model.viewToOriginal(hit.col), selectedRows),
      );
    }
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: 'copy_tsv',
        enabled: hasSel,
        child: const Text('Copy as TSV'),
      ),
      PopupMenuItem(
        value: 'copy_csv',
        enabled: hasSel,
        child: const Text('Copy as CSV'),
      ),
      if (widget.onOpenDetail != null && rowIndex != null) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'detail', child: Text('Open detail')),
      ],
      if (widget.onDeleteRow != null && rowIndex != null)
        const PopupMenuItem(value: 'delete', child: Text('Delete row…')),
      for (var i = 0; i < extras.length; i++) ...[
        if (i == 0 || extras[i].startsGroup) const PopupMenuDivider(),
        PopupMenuItem(
          value: 'extra:$i',
          enabled: extras[i].enabled,
          child: Tooltip(
            message: extras[i].enabled ? '' : (extras[i].disabledReason ?? ''),
            child: Row(
              children: [
                if (extras[i].icon != null) ...[
                  Icon(extras[i].icon, size: 16.0),
                  const SizedBox(width: 8.0),
                ],
                Flexible(child: Text(extras[i].label)),
              ],
            ),
          ),
        ),
      ],
    ];
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    );
    if (selected == 'copy_tsv') await _copyAs(_CopyFormat.tsv);
    if (selected == 'copy_csv') await _copyAs(_CopyFormat.csv);
    if (selected == 'detail' && rowIndex != null) {
      widget.onOpenDetail?.call(rowIndex);
    }
    if (selected == 'delete' && rowIndex != null) {
      widget.onDeleteRow?.call(rowIndex);
    }
    if (selected != null && selected.startsWith('extra:')) {
      final index = int.parse(selected.substring('extra:'.length));
      extras[index].onSelected?.call();
    }
  }
}

enum _CopyFormat { tsv, csv }

class _MoveIntent extends Intent {
  const _MoveIntent(this.deltaRow, this.deltaColumn);
  final int deltaRow;
  final int deltaColumn;
}

class _CopyIntent extends Intent {
  const _CopyIntent();
}

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _EditIntent extends Intent {
  const _EditIntent();
}

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.05),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 8.0),
          child: const SizedBox(
            width: 28.0,
            height: 28.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          ),
        ),
      ),
    );
  }
}

/// Sticky row-index gutter on the left of the grid. Click selects the
/// whole row, drag extends row selection, dragging the bottom 4 px of
/// any cell fires [onRowResizeDelta] so the caller can grow row height.
class _GutterColumn extends StatelessWidget {
  const _GutterColumn({
    required this.style,
    required this.headerHeight,
    required this.rowHeightFor,
    required this.rowCount,
    required this.scrollController,
    required this.selection,
    required this.onSelectRow,
    required this.onRowResizeDelta,
  });
  final GridStyle style;
  final double headerHeight;
  final double Function(int rowIdx) rowHeightFor;
  final int rowCount;
  final ScrollController scrollController;
  final CellRange? selection;
  final void Function(int row, {required bool extend}) onSelectRow;
  final void Function(int rowIdx, double delta) onRowResizeDelta;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kGutterWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: headerHeight,
            decoration: BoxDecoration(
              color: style.headerBackground,
              border: Border(
                right: BorderSide(color: style.cellBorder),
                bottom: BorderSide(color: style.cellBorder),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '#',
              style: style.headerSubtitleStyle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView.builder(
                controller: scrollController,
                itemExtentBuilder: (i, _) => rowHeightFor(i),
                itemCount: rowCount,
                itemBuilder: (_, i) {
                  final isSelected = selection != null &&
                      i >= selection!.rowMin &&
                      i <= selection!.rowMax;
                  return _GutterCell(
                    rowIndex: i,
                    height: rowHeightFor(i),
                    style: style,
                    isSelected: isSelected,
                    onTap: ({required extend}) =>
                        onSelectRow(i, extend: extend),
                    onResizeDelta: (delta) => onRowResizeDelta(i, delta),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GutterCell extends StatelessWidget {
  const _GutterCell({
    required this.rowIndex,
    required this.height,
    required this.style,
    required this.isSelected,
    required this.onTap,
    required this.onResizeDelta,
  });
  final int rowIndex;
  final double height;
  final GridStyle style;
  final bool isSelected;
  final void Function({required bool extend}) onTap;
  final ValueChanged<double> onResizeDelta;

  @override
  Widget build(BuildContext context) {
    final background = isSelected ? style.accentSoft : style.headerBackground;
    final foreground = isSelected ? style.textColor : style.mutedTextColor;
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final shift = HardwareKeyboard.instance.isShiftPressed;
            onTap(extend: shift);
          },
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: background,
              border: Border(
                right: BorderSide(color: style.cellBorder),
                bottom: BorderSide(color: style.cellBorder, width: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '${rowIndex + 1}',
              style: style.headerSubtitleStyle.copyWith(color: foreground),
            ),
          ),
        ),
        Positioned(
          left: 0.0,
          right: 0.0,
          bottom: 0.0,
          height: _kResizeHotZone,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (details) =>
                  onResizeDelta(details.delta.dy),
            ),
          ),
        ),
      ],
    );
  }
}

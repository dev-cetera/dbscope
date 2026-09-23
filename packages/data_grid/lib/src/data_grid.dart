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
const double _kResizeHotZone = 4;

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
  });

  @override
  State<DataGrid<TypeTag>> createState() => _DataGridState<TypeTag>();
}

class _DataGridState<TypeTag> extends State<DataGrid<TypeTag>> {
  late GridData<TypeTag> _currentData;
  final GridModel _model = GridModel();
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();
  final FocusNode _gridFocus = FocusNode(debugLabel: 'DataGrid');
  final ScrollController _gutterScroll = ScrollController();
  late final ValueNotifier<double> _fallbackRowHeight =
      ValueNotifier<double>(32);
  String? _sortColumn;
  bool _sortDescending = false;
  int? _lastReportedRowIdx;
  bool _syncingScroll = false;
  bool _isDragging = false;

  ValueListenable<double> get _rowHeightListenable =>
      widget.rowHeight ?? _fallbackRowHeight;
  double get _rowHeight => _rowHeightListenable.value;

  /// Per-row height overrides, keyed by row index. Lost on data
  /// replace; shifted when rows are inserted/removed at the top.
  final Map<int, double> _rowHeightOverrides = {};

  /// Effective height for the row at [rowIdx]: override if set,
  /// otherwise the default `rowHeight`.
  double _heightFor(int rowIdx) => _rowHeightOverrides[rowIdx] ?? _rowHeight;

  static const double _kMinRowHeight = 12;
  static const double _kMaxRowHeight = 1200;

  CellRenderer<TypeTag> get _renderer =>
      widget.cellRenderer ?? const DefaultCellRenderer();

  @override
  void initState() {
    super.initState();
    _currentData = widget.data;
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
        for (final c in _currentData.columns)
          c.defaultWidth ?? widget.defaultColumnWidth,
      ],
    );
    _model.setRowCount(_currentData.rows.length);
  }

  @override
  void didUpdateWidget(covariant DataGrid<TypeTag> old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
    final oldListenable = old.rowHeight ?? _fallbackRowHeight;
    final newListenable = widget.rowHeight ?? _fallbackRowHeight;
    if (!identical(oldListenable, newListenable)) {
      oldListenable.removeListener(_onRowHeightChanged);
      newListenable.addListener(_onRowHeightChanged);
    }
    if (widget.controller == null && !identical(old.data, widget.data)) {
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
    final s = _model.selection;
    final idx = s?.focusRow;
    if (idx != _lastReportedRowIdx) {
      _lastReportedRowIdx = idx;
      widget.onRowSelected?.call(idx);
    }
  }

  void _onVScroll() {
    if (widget.onLoadMore == null || !widget.hasMore || widget.isLoading) {
      return;
    }
    final p = _vScroll.position;
    if (p.pixels >= p.maxScrollExtent - 200) {
      widget.onLoadMore!();
    }
  }

  // --- Controller hooks --------------------------------------------------

  void _applyReplaceAll(GridData<TypeTag> data) {
    _currentData = data;
    _rowHeightOverrides.clear();
    _initModel();
    if (mounted) setState(() {});
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
      final prev = scroll.position.pixels;
      final target =
          (prev - removedExtent).clamp(0.0, scroll.position.maxScrollExtent);
      if (target != prev) scroll.jumpTo(target);
    }
    _model.setRowCount(_currentData.rows.length);
  }

  void _applyRemoveAt(int index) {
    if (index < 0 || index >= _currentData.rows.length) return;
    _currentData.rows.removeAt(index);
    _shiftOverridesFrom(index, -1);
    _model.setRowCount(_currentData.rows.length);
  }

  void _applyPrepend(List<Object?> row) {
    _currentData.rows.insert(0, row);
    _shiftOverrides(1);
    _model.setRowCount(_currentData.rows.length);
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

  void _applySetRowHeight(int rowIdx, double? height) {
    if (rowIdx < 0 || rowIdx >= _currentData.rows.length) return;
    if (height == null) {
      if (_rowHeightOverrides.remove(rowIdx) != null && mounted) {
        setState(() {});
      }
      return;
    }
    final clamped = height.clamp(_kMinRowHeight, _kMaxRowHeight).toDouble();
    if (_rowHeightOverrides[rowIdx] == clamped) return;
    _rowHeightOverrides[rowIdx] = clamped;
    if (mounted) setState(() {});
  }

  void _applyClearRowHeights() {
    if (_rowHeightOverrides.isEmpty) return;
    _rowHeightOverrides.clear();
    if (mounted) setState(() {});
  }

  void _onGutterResize(int rowIdx, double delta) {
    final current = _heightFor(rowIdx);
    final next =
        (current + delta).clamp(_kMinRowHeight, _kMaxRowHeight).toDouble();
    _applySetRowHeight(rowIdx, next);
    widget.onRowHeightChanged?.call(rowIdx, next);
  }

  void _applyUpdateCell(int rowIdx, String column, Object? value) {
    if (rowIdx < 0 || rowIdx >= _currentData.rows.length) return;
    final colIdx = _currentData.columns.indexWhere((c) => c.name == column);
    if (colIdx < 0) return;
    _currentData.rows[rowIdx][colIdx] = value;
    if (mounted) setState(() {});
  }

  // --- Sort / reorder / resize ------------------------------------------

  void _onSortToggle(int originalIdx) {
    if (widget.onSort == null) return;
    final col = _currentData.columns[originalIdx];
    final desc = _sortColumn == col.name ? !_sortDescending : false;
    setState(() {
      _sortColumn = col.name;
      _sortDescending = desc;
    });
    widget.onSort!(GridSortEvent(col.name, desc));
  }

  void _onWidthChanged(int originalIdx, double width) =>
      _model.setColumnWidth(originalIdx, width);

  void _onReorder(int fromView, int toView) =>
      _model.reorderColumn(fromView, toView);

  // --- Cell interaction --------------------------------------------------

  void _onCellTap(int row, int col, bool extend) {
    if (extend) {
      _model.extendSelection(row, col);
    } else {
      _model.selectSingle(row, col);
    }
    _gridFocus.requestFocus();
  }

  void _onCellDoubleTap(int row, int col) {
    final editor = widget.cellEditor;
    if (editor == null) return;
    final originalIdx = _model.viewToOriginal(col);
    final spec = _currentData.columns[originalIdx];
    if (!editor.canEdit(spec)) return;
    if (widget.onCellEdit == null) return;
    if (editor.requiresDialog(spec)) {
      _editViaDialog(row, originalIdx, spec);
      return;
    }
    _model.beginEdit(row, col);
  }

  Future<void> _editViaDialog(
    int row,
    int originalIdx,
    GridColumnSpec<TypeTag> spec,
  ) async {
    final editor = widget.cellEditor!;
    final oldValue = _currentData.rows[row][originalIdx];
    final result = await editor.openDialog(context, oldValue, spec);
    if (result == null) return;
    if (result == oldValue) return;
    widget.onCellEdit?.call(
      GridEditEvent(row, spec.name, oldValue, result),
    );
  }

  ({int row, int col})? _hitTest(Offset localPos) {
    if (localPos.dy < 0 || localPos.dx < 0) return null;
    if (_currentData.rows.isEmpty || _model.order.isEmpty) return null;
    final vOffset = _vScroll.hasClients ? _vScroll.offset : 0.0;
    final targetY = vOffset + localPos.dy;
    final int absRow;
    if (_rowHeightOverrides.isEmpty) {
      // Fast path: every row has the default height.
      absRow = (targetY ~/ _rowHeight);
    } else {
      // Mixed heights: walk forward summing extents. In practice
      // overrides are a small map and the visible window is bounded,
      // so this is fast enough for the hit-test path.
      var acc = 0.0;
      var found = -1;
      for (var i = 0; i < _currentData.rows.length; i++) {
        final h = _heightFor(i);
        if (targetY < acc + h) {
          found = i;
          break;
        }
        acc += h;
      }
      if (found < 0) return null;
      absRow = found;
    }
    if (absRow < 0 || absRow >= _currentData.rows.length) return null;
    var acc = 0.0;
    for (var v = 0; v < _model.order.length; v++) {
      final w = _model.widthAt(v);
      if (localPos.dx >= acc && localPos.dx < acc + w) {
        return (row: absRow, col: v);
      }
      acc += w;
    }
    return null;
  }

  void _onBodyPointerDown(PointerDownEvent e, Offset localPos) {
    if (e.buttons != kPrimaryButton) return;
    if (_model.isEditing) return;
    final hit = _hitTest(localPos);
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

  void _onBodyPointerMove(PointerMoveEvent e, Offset localPos) {
    if (!_isDragging) return;
    if (e.buttons != kPrimaryButton) {
      _isDragging = false;
      return;
    }
    final hit = _hitTest(localPos);
    if (hit == null) return;
    _model.extendSelection(hit.row, hit.col);
  }

  void _onBodyPointerUp(PointerUpEvent e) {
    _isDragging = false;
  }

  void _onCommit(int row, int col, Object? newValue) {
    final originalIdx = _model.viewToOriginal(col);
    final spec = _currentData.columns[originalIdx];
    final oldValue = _currentData.rows[row][originalIdx];
    _model.endEdit();
    if (widget.onCellEdit == null) return;
    if (newValue == oldValue) return;
    widget.onCellEdit!(GridEditEvent(row, spec.name, oldValue, newValue));
  }

  void _onCancelEdit() => _model.endEdit();

  void _onKeyMove(int dRow, int dCol) {
    final s = _model.selection;
    if (s == null) {
      if (_currentData.rows.isNotEmpty && _model.order.isNotEmpty) {
        _model.selectSingle(0, 0);
      }
      return;
    }
    final nextRow = (s.focusRow + dRow).clamp(0, _currentData.rows.length - 1);
    final nextCol = (s.focusCol + dCol).clamp(0, _model.order.length - 1);
    _model.selectSingle(nextRow, nextCol);
  }

  Future<void> _onCopyRequest() => _copyAs(_CopyFormat.tsv);

  Future<void> _copyAs(_CopyFormat format) async {
    final s = _model.selection;
    if (s == null) return;
    final text = switch (format) {
      _CopyFormat.tsv => serializeRangeAsTsv(_currentData, _model, s),
      _CopyFormat.csv => serializeRangeAsCsv(_currentData, _model, s),
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
        padding: const EdgeInsets.all(12),
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
          if (!_model.isEditing) _onKeyMove(intent.dRow, intent.dCol);
          return null;
        },
      ),
      _CopyIntent: CallbackAction<_CopyIntent>(
        onInvoke: (_) {
          if (!_model.isEditing) _onCopyRequest();
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
          final s = _model.selection;
          if (s != null && !_model.isEditing) {
            _onCellDoubleTap(s.focusRow, s.focusCol);
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
          notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
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
                  ),
                  Expanded(
                    child: GestureDetector(
                      onSecondaryTapDown: (d) =>
                          _showContextMenu(d.globalPosition),
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
                          notificationPredicate: (n) =>
                              n.metrics.axis == Axis.vertical,
                          child: ListView.builder(
                            controller: _vScroll,
                            itemExtentBuilder: (i, _) => _heightFor(i),
                            itemCount: _currentData.rows.length,
                            itemBuilder: (ctx, i) {
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
          onSelectRow: (row, extend) {
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

  Future<void> _showContextMenu(Offset position) async {
    final selection = _model.selection;
    final rowIdx = selection?.focusRow;
    final hasSel = selection != null;
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
      if (widget.onOpenDetail != null && rowIdx != null) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'detail', child: Text('Open detail')),
      ],
      if (widget.onDeleteRow != null && rowIdx != null)
        const PopupMenuItem(value: 'delete', child: Text('Delete row…')),
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
    if (selected == 'detail' && rowIdx != null) {
      widget.onOpenDetail?.call(rowIdx);
    }
    if (selected == 'delete' && rowIdx != null) {
      widget.onDeleteRow?.call(rowIdx);
    }
  }
}

enum _CopyFormat { tsv, csv }

class _MoveIntent extends Intent {
  final int dRow;
  final int dCol;
  const _MoveIntent(this.dRow, this.dCol);
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
          padding: const EdgeInsets.only(top: 8),
          child: const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

/// Sticky row-index gutter on the left of the grid. Click selects the
/// whole row, drag extends row selection, dragging the bottom 4 px of
/// any cell fires [onResizeDelta] so the caller can grow row height.
class _GutterColumn extends StatelessWidget {
  final GridStyle style;
  final double headerHeight;
  final double Function(int rowIdx) rowHeightFor;
  final int rowCount;
  final ScrollController scrollController;
  final CellRange? selection;
  final void Function(int row, bool extend) onSelectRow;
  final void Function(int rowIdx, double delta) onRowResizeDelta;

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
                    rowIdx: i,
                    height: rowHeightFor(i),
                    style: style,
                    isSelected: isSelected,
                    onTap: (extend) => onSelectRow(i, extend),
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
  final int rowIdx;
  final double height;
  final GridStyle style;
  final bool isSelected;
  final void Function(bool extend) onTap;
  final ValueChanged<double> onResizeDelta;

  const _GutterCell({
    required this.rowIdx,
    required this.height,
    required this.style,
    required this.isSelected,
    required this.onTap,
    required this.onResizeDelta,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isSelected ? style.accentSoft : style.headerBackground;
    final fg = isSelected ? style.textColor : style.mutedTextColor;
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final shift = HardwareKeyboard.instance.isShiftPressed;
            onTap(shift);
          },
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: bg,
              border: Border(
                right: BorderSide(color: style.cellBorder),
                bottom: BorderSide(color: style.cellBorder, width: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '${rowIdx + 1}',
              style: style.headerSubtitleStyle.copyWith(color: fg),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _kResizeHotZone,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (d) => onResizeDelta(d.delta.dy),
            ),
          ),
        ),
      ],
    );
  }
}

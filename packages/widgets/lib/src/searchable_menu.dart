import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One row in a [showSearchableMenu]. [searchKey] is the text matched
/// against the filter; [child] is what renders. [value] is what
/// [showSearchableMenu] returns on selection. A null [value] makes the
/// row unselectable (used for headers / unselectable groupings).
class SearchableMenuItem<T> {
  final T? value;
  final String searchKey;
  final Widget child;
  final bool enabled;

  /// Optional inline secondary action. When non-null, a trailing
  /// [secondaryIcon] is rendered to the right of [child]; clicking it
  /// runs [onSecondary] and closes the popup without selecting the
  /// row. Use for per-row destructive affordances (delete, etc.) that
  /// don't need their own row.
  final VoidCallback? onSecondary;
  final IconData? secondaryIcon;
  final String? secondaryTooltip;

  const SearchableMenuItem({
    required this.value,
    required this.searchKey,
    required this.child,
    this.enabled = true,
    this.onSecondary,
    this.secondaryIcon,
    this.secondaryTooltip,
  });
}

/// Opens a popup anchored at [position] (in global coordinates) with a
/// text filter at the top and the matching subset of [items] below.
/// Type-to-narrow; Up/Down moves the highlight; Enter selects; Escape
/// cancels. Returns the [SearchableMenuItem.value] of the chosen row,
/// or null when dismissed.
///
/// [hint] is the placeholder text in the filter box; [emptyLabel] is
/// shown when no items match. Width is fixed to [width]; height adapts
/// to contents up to [maxHeight].
Future<T?> showSearchableMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<SearchableMenuItem<T>> items,
  String hint = 'Filter...',
  String emptyLabel = 'No matches',
  double width = 320,
  double maxHeight = 360,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;
  final screen = overlay.size;
  // Clamp position so the popup never paints off-screen.
  final x = position.dx.clamp(
    0.0,
    (screen.width - width).clamp(0.0, screen.width),
  );
  final y = position.dy.clamp(
    0.0,
    (screen.height - maxHeight).clamp(0.0, screen.height),
  );
  return showDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    builder:
        (ctx) => _SearchablePopup<T>(
          anchor: Offset(x, y),
          items: items,
          hint: hint,
          emptyLabel: emptyLabel,
          width: width,
          maxHeight: maxHeight,
        ),
  );
}

class _SearchablePopup<T> extends StatefulWidget {
  final Offset anchor;
  final List<SearchableMenuItem<T>> items;
  final String hint;
  final String emptyLabel;
  final double width;
  final double maxHeight;

  const _SearchablePopup({
    required this.anchor,
    required this.items,
    required this.hint,
    required this.emptyLabel,
    required this.width,
    required this.maxHeight,
  });

  @override
  State<_SearchablePopup<T>> createState() => _SearchablePopupState<T>();
}

class _SearchablePopupState<T> extends State<_SearchablePopup<T>> {
  final _filterCtrl = TextEditingController();
  final _filterFocus = FocusNode();
  String _filter = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    // Autofocus after the route's enter transition so the keystrokes
    // that opened the menu don't get captured by the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  List<SearchableMenuItem<T>> get _matches {
    if (_filter.isEmpty) return widget.items;
    final f = _filter.toLowerCase();
    return widget.items
        .where((e) => e.searchKey.toLowerCase().contains(f))
        .toList();
  }

  void _moveHighlight(int delta) {
    final matches = _matches;
    final selectable = <int>[
      for (var i = 0; i < matches.length; i++)
        if (matches[i].value != null && matches[i].enabled) i,
    ];
    if (selectable.isEmpty) return;
    final currentIdxInSelectable = selectable.indexOf(_highlight);
    final next =
        currentIdxInSelectable < 0
            ? 0
            : (currentIdxInSelectable + delta).clamp(0, selectable.length - 1);
    setState(() => _highlight = selectable[next]);
  }

  void _selectHighlight() {
    final matches = _matches;
    if (_highlight < 0 || _highlight >= matches.length) return;
    final picked = matches[_highlight];
    if (picked.value == null || !picked.enabled) return;
    Navigator.of(context).pop<T>(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _matches;
    return Stack(
      children: [
        // Tap-outside-to-dismiss layer.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          left: widget.anchor.dx,
          top: widget.anchor.dy,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(6),
            color: theme.colorScheme.surface,
            child: SizedBox(
              width: widget.width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.maxHeight),
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape):
                        () => Navigator.of(context).pop(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        () => _moveHighlight(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        () => _moveHighlight(-1),
                    const SingleActivator(LogicalKeyboardKey.enter):
                        _selectHighlight,
                    const SingleActivator(LogicalKeyboardKey.numpadEnter):
                        _selectHighlight,
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                        child: TextField(
                          controller: _filterCtrl,
                          focusNode: _filterFocus,
                          decoration: InputDecoration(
                            hintText: widget.hint,
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 16),
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          onChanged: (v) {
                            setState(() {
                              _filter = v;
                              _highlight = 0;
                            });
                          },
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child:
                            matches.isEmpty
                                ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    widget.emptyLabel,
                                    style: TextStyle(color: theme.hintColor),
                                  ),
                                )
                                : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: matches.length,
                                  itemBuilder: (_, i) {
                                    final item = matches[i];
                                    final selectable =
                                        item.value != null && item.enabled;
                                    final highlighted = i == _highlight;
                                    return InkWell(
                                      onTap:
                                          selectable
                                              ? () => Navigator.of(
                                                context,
                                              ).pop<T>(item.value)
                                              : null,
                                      child: Container(
                                        color:
                                            highlighted && selectable
                                                ? theme
                                                    .colorScheme
                                                    .primaryContainer
                                                    .withValues(alpha: 0.4)
                                                : null,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(child: item.child),
                                            if (item.onSecondary != null) ...[
                                              const SizedBox(width: 4),
                                              GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () {
                                                  final cb = item.onSecondary!;
                                                  Navigator.of(context).pop();
                                                  cb();
                                                },
                                                child: Tooltip(
                                                  message:
                                                      item.secondaryTooltip ??
                                                      '',
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(4),
                                                    child: Icon(
                                                      item.secondaryIcon ??
                                                          Icons.close,
                                                      size: 14,
                                                      color: theme.hintColor,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'context_menu.dart';

/// One choice in an [InstantDropdown].
class InstantDropdownItem {
  const InstantDropdownItem({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });
  final String label;

  /// A disabled item is listed but can't be picked.
  final bool enabled;

  /// Whether this is the current value. The button shows the first
  /// selected item's label, or the hint when none is selected.
  final bool selected;
  final VoidCallback onSelected;
}

/// A compact dropdown that opens its menu at once.
///
/// Use it instead of `DropdownButton`, whose menu route always takes
/// 300 ms to open (Flutter hard-codes the duration and offers no hook).
/// The menu is a plain `showMenu` with [kInstantPopUp], placed just
/// below the button, with the current value checked.
///
/// Give it a [decoration] to stand in for `DropdownButtonFormField`: the
/// button is then drawn as an input field with that label and border.
class InstantDropdown extends StatelessWidget {
  const InstantDropdown({
    super.key,
    required this.items,
    this.enabled = true,
    this.hint = '',
    this.style,
    this.isExpanded = false,
    this.focusNode,
    this.decoration,
  });
  final List<InstantDropdownItem> items;
  final bool enabled;
  final String hint;
  final TextStyle? style;

  /// Fill the available width, like `DropdownButton.isExpanded`.
  final bool isExpanded;
  final FocusNode? focusNode;

  /// Draw the button as a form field. Null draws a bare label and arrow.
  final InputDecoration? decoration;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final buttonRect = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final picked = await showMenu<InstantDropdownItem>(
      context: context,
      popUpAnimationStyle: kInstantPopUp,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(buttonRect.left, buttonRect.bottom, buttonRect.width, 0.0),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints(minWidth: buttonRect.width),
      items: [
        for (final item in items)
          CheckedPopupMenuItem<InstantDropdownItem>(
            value: item,
            enabled: item.enabled,
            checked: item.selected,
            height: 32.0,
            child: Text(item.label, style: style),
          ),
      ],
    );
    picked?.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = style ?? theme.textTheme.bodyMedium;
    String? selectedLabel;
    for (final item in items) {
      if (item.selected) {
        selectedLabel = item.label;
        break;
      }
    }
    final label = Text(
      selectedLabel ?? hint,
      overflow: TextOverflow.ellipsis,
      style:
          selectedLabel == null || !enabled
              ? textStyle?.copyWith(color: theme.disabledColor)
              : textStyle,
    );
    final content = Row(
      mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (isExpanded) Expanded(child: label) else Flexible(child: label),
        Icon(
          Icons.arrow_drop_down,
          size: 16.0,
          color: enabled ? textStyle?.color : theme.disabledColor,
        ),
      ],
    );
    final decoration = this.decoration;
    // Read as one button named for the field, with the current choice as its
    // value, so a screen reader or an agent reads `button "Kind"
    // value="Postgres"` instead of loose text.
    final fieldName = decoration?.labelText ?? '';
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: fieldName.isEmpty ? (selectedLabel ?? hint) : fieldName,
      value: fieldName.isEmpty ? null : (selectedLabel ?? hint),
      excludeSemantics: true,
      onTap: enabled ? () => _open(context) : null,
      child: InkWell(
        focusNode: focusNode,
        canRequestFocus: enabled,
        onTap: enabled ? () => _open(context) : null,
        child:
            decoration == null
                ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                  child: content,
                )
                : InputDecorator(
                  decoration: decoration.copyWith(enabled: enabled),
                  isEmpty: selectedLabel == null && hint.isEmpty,
                  child: content,
                ),
      ),
    );
  }
}

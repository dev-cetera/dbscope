part of '../column_input.dart';

class _EnumInput extends StatelessWidget {
  const _EnumInput({
    required this.values,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.focusNode,
  });
  final List<String> values;
  final String? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final textStyle = TextStyle(
      color: enabled ? palette.text : palette.mutedText,
      fontSize: palette.bodyFontSize,
      fontFamily: palette.uiFontFamily,
    );
    return _Field(
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      child: InstantDropdown(
        enabled: enabled,
        focusNode: focusNode,
        isExpanded: true,
        style: textStyle,
        hint: '— pick —',
        items: [
          for (final option in values)
            InstantDropdownItem(
              label: option,
              selected: option == value,
              onSelected: () => onChanged(option),
            ),
        ],
      ),
    );
  }
}

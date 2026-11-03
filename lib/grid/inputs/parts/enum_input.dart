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
    final present = value != null && values.contains(value);
    final textStyle = TextStyle(
      color: enabled ? palette.text : palette.mutedText,
      fontSize: palette.bodyFontSize,
      fontFamily: palette.uiFontFamily,
    );
    return _Field(
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: present ? value : null,
          focusNode: focusNode,
          isDense: true,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, size: 16.0),
          style: textStyle,
          dropdownColor: palette.surface,
          hint: Text(
            '— pick —',
            style: textStyle.copyWith(color: palette.mutedText),
          ),
          items: [
            for (final option in values) DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

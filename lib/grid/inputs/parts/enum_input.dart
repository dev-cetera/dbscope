part of '../column_input.dart';

class _EnumInput extends StatelessWidget {
  final List<String> values;
  final String? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  const _EnumInput({
    required this.values,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: present ? value : null,
          isDense: true,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, size: 16),
          style: textStyle,
          dropdownColor: palette.surface,
          hint: Text(
            '— pick —',
            style: textStyle.copyWith(color: palette.mutedText),
          ),
          items: [
            for (final v in values) DropdownMenuItem(value: v, child: Text(v)),
          ],
          onChanged: enabled ? (v) => onChanged(v) : null,
        ),
      ),
    );
  }
}

part of '../column_input.dart';

class _BoolInput extends StatelessWidget {
  final bool? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  const _BoolInput({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<bool>(
          value: value,
          isDense: true,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, size: 16),
          style: textStyle,
          dropdownColor: palette.surface,
          hint: Text(
            '— pick —',
            style: textStyle.copyWith(color: palette.mutedText),
          ),
          items: const [
            DropdownMenuItem(value: true, child: Text('true')),
            DropdownMenuItem(value: false, child: Text('false')),
          ],
          onChanged: enabled ? (v) => onChanged(v) : null,
        ),
      ),
    );
  }
}

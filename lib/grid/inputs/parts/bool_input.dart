part of '../column_input.dart';

class _BoolInput extends StatelessWidget {
  const _BoolInput({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final bool? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

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
      child: DropdownButtonHideUnderline(
        child: DropdownButton<bool>(
          value: value,
          isDense: true,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, size: 16.0),
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
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

part of '../column_input.dart';

class _NumberInput extends StatelessWidget {
  const _NumberInput({
    required this.value,
    required this.enabled,
    required this.allowDecimal,
    required this.onChanged,
  });
  final String? value;
  final bool enabled;
  final bool allowDecimal;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final pattern = allowDecimal ? RegExp(r'^-?\d*\.?\d*$') : RegExp(r'^-?\d*$');
    return _RawTextInput(
      value: value,
      enabled: enabled,
      monospace: true,
      hint: allowDecimal ? '0.0' : '0',
      keyboardType: TextInputType.numberWithOptions(
        signed: true,
        decimal: allowDecimal,
      ),
      formatters: [
        FilteringTextInputFormatter.allow(
          allowDecimal ? RegExp(r'[0-9\.\-]') : RegExp(r'[0-9\-]'),
        ),
        TextInputFormatter.withFunction((oldValue, newValue) {
          if (newValue.text.isEmpty || pattern.hasMatch(newValue.text)) {
            return newValue;
          }
          return oldValue;
        }),
      ],
      onChanged: onChanged,
    );
  }
}

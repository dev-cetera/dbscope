part of '../column_input.dart';

class _NumberInput extends StatelessWidget {
  final String? value;
  final bool enabled;
  final bool allowDecimal;
  final ValueChanged<Object?> onChanged;

  const _NumberInput({
    required this.value,
    required this.enabled,
    required this.allowDecimal,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pattern = allowDecimal
        ? RegExp(r'^-?\d*\.?\d*$')
        : RegExp(r'^-?\d*$');
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
        TextInputFormatter.withFunction((oldVal, newVal) {
          if (newVal.text.isEmpty || pattern.hasMatch(newVal.text)) {
            return newVal;
          }
          return oldVal;
        }),
      ],
      onChanged: onChanged,
    );
  }
}

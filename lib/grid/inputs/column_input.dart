library;

import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../../catalog/pg_type.dart';
import '../../db/edit_policy.dart';

part 'parts/bool_input.dart';
part 'parts/date_input.dart';
part 'parts/enum_input.dart';
part 'parts/json_input.dart';
part 'parts/number_input.dart';
part 'parts/raw_text_input.dart';
part 'parts/shared.dart';
part 'parts/smart_text_input.dart';

/// A type-aware input widget for one column of a row insert/edit dialog.
///
/// Picks the right variant via [ColumnInput.forPolicy] based on the column's
/// [PgType] and enum membership. All variants emit either `null` (when the
/// user toggles the NULL button on a nullable column) or a String/bool that
/// `CellEditor.parseValue` accepts.
class ColumnInput extends StatefulWidget {
  const ColumnInput({
    super.key,
    required this.policy,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  factory ColumnInput.forPolicy({
    Key? key,
    required EditPolicy policy,
    required Object? value,
    required ValueChanged<Object?> onChanged,
    bool enabled = true,
    bool compact = false,
  }) {
    return ColumnInput(
      key: key,
      policy: policy,
      value: value,
      onChanged: onChanged,
      enabled: enabled,
      compact: compact,
    );
  }
  final EditPolicy policy;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool enabled;

  /// When true, drops the column-name / type / NULL header row and the
  /// trailing padding. Used for in-grid cell editing where the parent
  /// already shows the column name in the header and the row height
  /// is fixed.
  final bool compact;

  @override
  State<ColumnInput> createState() => _ColumnInputState();
}

class _ColumnInputState extends State<ColumnInput> {
  var _isNull = false;
  Object? _lastNonNullValue;

  @override
  void initState() {
    super.initState();
    _isNull = false;
    _lastNonNullValue = widget.value;
  }

  void _setNull(bool toNull) {
    setState(() {
      _isNull = toNull;
      if (toNull) {
        _lastNonNullValue = widget.value;
        widget.onChanged(null);
      } else {
        widget.onChanged(_lastNonNullValue);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final policy = widget.policy;
    final palette = AppPalette.of(context);
    final disabled = !widget.enabled || _isNull;
    final field = _ColumnInputField(
      policy: policy,
      value: widget.value,
      enabled: !disabled,
      onChanged: widget.onChanged,
    );

    if (widget.compact) {
      // Inline cell-edit form: no header row, no bottom padding. The
      // NULL toggle (if applicable) sits to the right of the input
      // instead of above.
      final input = _isNull ? const _NullPlaceholder() : field;
      if (!policy.nullable) return input;
      return Row(
        children: [
          Expanded(child: input),
          const SizedBox(width: 4.0),
          _NullButton(
            isNull: _isNull,
            enabled: widget.enabled,
            onToggle: () => _setNull(!_isNull),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${policy.column} ',
                  style: palette.boldText,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                policy.typeName,
                style: TextStyle(
                  color: palette.mutedText,
                  fontSize: palette.smallFontSize,
                  fontFamily: palette.uiFontFamily,
                ),
              ),
              if (policy.nullable)
                Padding(
                  padding: const EdgeInsets.only(left: 6.0),
                  child: _NullButton(
                    isNull: _isNull,
                    enabled: widget.enabled,
                    onToggle: () => _setNull(!_isNull),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3.0),
          if (_isNull) const _NullPlaceholder() else field,
        ],
      ),
    );
  }
}

/// The type-specific input (text, number, date, JSON, …) for one column,
/// picked from the column's [PgType]. Greyed out when [enabled] is false.
class _ColumnInputField extends StatelessWidget {
  const _ColumnInputField({
    required this.policy,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final EditPolicy policy;
  final Object? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final raw = value;
    final asString = raw == null
        ? null
        : (raw is String ? raw : raw.toString());
    if (policy.enumValues != null && policy.enumValues!.isNotEmpty) {
      return _EnumInput(
        values: policy.enumValues!,
        value: asString,
        enabled: enabled,
        onChanged: onChanged,
      );
    }
    switch (policy.type) {
      case PgType.bool_:
        return _BoolInput(
          value: raw is bool ? raw : _parseBool(asString),
          enabled: enabled,
          onChanged: onChanged,
        );
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
        return _NumberInput(
          value: asString,
          enabled: enabled,
          allowDecimal: false,
          onChanged: onChanged,
        );
      case PgType.numeric:
      case PgType.real:
      case PgType.doublePrecision:
        return _NumberInput(
          value: asString,
          enabled: enabled,
          allowDecimal: true,
          onChanged: onChanged,
        );
      case PgType.json:
      case PgType.jsonb:
        return _JsonInput(
          value: asString,
          enabled: enabled,
          onChanged: onChanged,
        );
      case PgType.date:
        return _DateInput(
          value: asString,
          enabled: enabled,
          mode: CupertinoDatePickerMode.date,
          onChanged: onChanged,
        );
      case PgType.time:
        return _DateInput(
          value: asString,
          enabled: enabled,
          mode: CupertinoDatePickerMode.time,
          onChanged: onChanged,
        );
      case PgType.timestamp:
      case PgType.timestamptz:
        return _DateInput(
          value: asString,
          enabled: enabled,
          mode: CupertinoDatePickerMode.dateAndTime,
          onChanged: onChanged,
        );
      case PgType.text:
      case PgType.varchar:
      case PgType.name:
        return _SmartTextInput(
          value: asString,
          enabled: enabled,
          multiLine: policy.multiLine,
          onChanged: onChanged,
        );
      case PgType.uuid:
        return _RawTextInput(
          value: asString,
          enabled: enabled,
          hint: '00000000-0000-0000-0000-000000000000',
          monospace: true,
          onChanged: onChanged,
        );
      case PgType.interval:
      case PgType.bytea:
      case PgType.array:
      case PgType.unknown:
        return _RawTextInput(
          value: asString,
          enabled: enabled,
          multiLine: policy.multiLine,
          onChanged: onChanged,
        );
    }
  }
}

/// Minify a JSON string for storage. Returns the input unchanged if
/// it isn't parseable as JSON. Mirror of `_JsonInputState._pretty` —
/// `_pretty` is used on entering edit mode, `compactJson` is used on
/// saving so the database stores the most compact form.
String compactJson(String input) {
  if (input.isEmpty) return input;
  try {
    return jsonEncode(jsonDecode(input));
  } catch (_) {
    return input;
  }
}

bool? _parseBool(String? text) {
  if (text == null) return null;
  final lower = text.toLowerCase();
  if (lower == 'true' || lower == 't' || lower == '1') return true;
  if (lower == 'false' || lower == 'f' || lower == '0') return false;
  return null;
}

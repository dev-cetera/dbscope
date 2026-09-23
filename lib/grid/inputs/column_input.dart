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
  final EditPolicy policy;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool enabled;

  /// When true, drops the column-name / type / NULL header row and the
  /// trailing padding. Used for in-grid cell editing where the parent
  /// already shows the column name in the header and the row height
  /// is fixed.
  final bool compact;

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

  @override
  State<ColumnInput> createState() => _ColumnInputState();
}

class _ColumnInputState extends State<ColumnInput> {
  bool _isNull = false;
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
    final p = widget.policy;
    final palette = AppPalette.of(context);
    final disabled = !widget.enabled || _isNull;

    if (widget.compact) {
      // Inline cell-edit form: no header row, no bottom padding. The
      // NULL toggle (if applicable) sits to the right of the input
      // instead of above.
      final input = _isNull ? const _NullPlaceholder() : _buildChild(disabled);
      if (!p.nullable) return input;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: input),
          const SizedBox(width: 4),
          _NullButton(
            isNull: _isNull,
            enabled: widget.enabled,
            onToggle: () => _setNull(!_isNull),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${p.column} ',
                  style: palette.boldText,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                p.typeName,
                style: TextStyle(
                  color: palette.mutedText,
                  fontSize: palette.smallFontSize,
                  fontFamily: palette.uiFontFamily,
                ),
              ),
              if (p.nullable)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _NullButton(
                    isNull: _isNull,
                    enabled: widget.enabled,
                    onToggle: () => _setNull(!_isNull),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          _isNull ? const _NullPlaceholder() : _buildChild(disabled),
        ],
      ),
    );
  }

  Widget _buildChild(bool disabled) {
    final p = widget.policy;
    final raw = widget.value;
    final asString = raw == null
        ? null
        : (raw is String ? raw : raw.toString());
    if (p.enumValues != null && p.enumValues!.isNotEmpty) {
      return _EnumInput(
        values: p.enumValues!,
        value: asString,
        enabled: !disabled,
        onChanged: widget.onChanged,
      );
    }
    switch (p.type) {
      case PgType.bool_:
        return _BoolInput(
          value: raw is bool ? raw : _parseBool(asString),
          enabled: !disabled,
          onChanged: widget.onChanged,
        );
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
        return _NumberInput(
          value: asString,
          enabled: !disabled,
          allowDecimal: false,
          onChanged: widget.onChanged,
        );
      case PgType.numeric:
      case PgType.real:
      case PgType.doublePrecision:
        return _NumberInput(
          value: asString,
          enabled: !disabled,
          allowDecimal: true,
          onChanged: widget.onChanged,
        );
      case PgType.json:
      case PgType.jsonb:
        return _JsonInput(
          value: asString,
          enabled: !disabled,
          onChanged: widget.onChanged,
        );
      case PgType.date:
        return _DateInput(
          value: asString,
          enabled: !disabled,
          mode: CupertinoDatePickerMode.date,
          onChanged: widget.onChanged,
        );
      case PgType.time:
        return _DateInput(
          value: asString,
          enabled: !disabled,
          mode: CupertinoDatePickerMode.time,
          onChanged: widget.onChanged,
        );
      case PgType.timestamp:
      case PgType.timestamptz:
        return _DateInput(
          value: asString,
          enabled: !disabled,
          mode: CupertinoDatePickerMode.dateAndTime,
          onChanged: widget.onChanged,
        );
      case PgType.text:
      case PgType.varchar:
      case PgType.name:
        return _SmartTextInput(
          value: asString,
          enabled: !disabled,
          multiLine: p.multiLine,
          onChanged: widget.onChanged,
        );
      case PgType.uuid:
        return _RawTextInput(
          value: asString,
          enabled: !disabled,
          hint: '00000000-0000-0000-0000-000000000000',
          monospace: true,
          onChanged: widget.onChanged,
        );
      default:
        return _RawTextInput(
          value: asString,
          enabled: !disabled,
          multiLine: p.multiLine,
          onChanged: widget.onChanged,
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

bool? _parseBool(String? s) {
  if (s == null) return null;
  final l = s.toLowerCase();
  if (l == 'true' || l == 't' || l == '1') return true;
  if (l == 'false' || l == 'f' || l == '0') return false;
  return null;
}

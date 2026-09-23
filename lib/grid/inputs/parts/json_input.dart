part of '../column_input.dart';

class _JsonInput extends StatefulWidget {
  final String? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  const _JsonInput({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_JsonInput> createState() => _JsonInputState();
}

class _JsonInputState extends State<_JsonInput> {
  late String _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    final raw = widget.value ?? '';
    _text = _pretty(raw);
    _validate(_text);
    if (_text != raw) {
      // Push the formatted text up so saving doesn't have to look at
      // the raw value.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(_text);
      });
    }
  }

  static String _pretty(String input) {
    if (input.isEmpty) return input;
    try {
      return const JsonEncoder.withIndent(' ').convert(jsonDecode(input));
    } catch (_) {
      return input;
    }
  }

  void _validate(String s) {
    if (s.isEmpty) {
      _error = null;
      return;
    }
    try {
      jsonDecode(s);
      _error = null;
    } catch (e) {
      _error = 'Invalid JSON';
    }
  }

  void _format() {
    if (_text.isEmpty) return;
    try {
      const encoder = JsonEncoder.withIndent(' ');
      final pretty = encoder.convert(jsonDecode(_text));
      setState(() {
        _text = pretty;
        _error = null;
      });
      widget.onChanged(pretty);
    } catch (_) {
      setState(() => _error = 'Invalid JSON');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RawTextInput(
          value: _text,
          enabled: widget.enabled,
          multiLine: true,
          monospace: true,
          hint: '{"key": "value"}',
          onChanged: (v) {
            final s = v as String? ?? '';
            _text = s;
            setState(() => _validate(s));
            widget.onChanged(s);
          },
          suffix: widget.enabled
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _format,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Tooltip(
                        message: 'Format JSON',
                        child: Icon(Icons.auto_fix_high, size: 14),
                      ),
                    ),
                  ),
                )
              : null,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 2),
            child: Text(
              _error!,
              style: TextStyle(
                color: const Color(0xFF8B0000),
                fontSize: palette.smallFontSize,
                fontFamily: palette.uiFontFamily,
              ),
            ),
          ),
      ],
    );
  }
}

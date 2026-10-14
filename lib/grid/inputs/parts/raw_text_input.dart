part of '../column_input.dart';

class _RawTextInput extends StatefulWidget {
  const _RawTextInput({
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.multiLine = false,
    this.monospace = false,
    this.hint,
    this.formatters,
    this.keyboardType,
    this.prefix,
    this.suffix,
  });
  final String? value;
  final bool enabled;
  final bool multiLine;
  final bool monospace;
  final String? hint;
  final ValueChanged<Object?> onChanged;
  final List<TextInputFormatter>? formatters;
  final TextInputType? keyboardType;
  final Widget? prefix;
  final Widget? suffix;

  @override
  State<_RawTextInput> createState() => _RawTextInputState();
}

class _RawTextInputState extends State<_RawTextInput> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.value ?? '');
    _textController.addListener(_handleChange);
  }

  void _handleChange() {
    widget.onChanged(_textController.text);
  }

  @override
  void didUpdateWidget(covariant _RawTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.value ?? '';
    if (incoming != _textController.text) {
      _textController.removeListener(_handleChange);
      _textController.value = TextEditingValue(
        text: incoming,
        selection: TextSelection.collapsed(offset: incoming.length),
      );
      _textController.addListener(_handleChange);
    }
  }

  @override
  void dispose() {
    _textController.removeListener(_handleChange);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = TextStyle(
      color: widget.enabled ? palette.text : palette.mutedText,
      fontSize: palette.bodyFontSize,
      fontFamily: widget.monospace
          ? palette.monoFontFamily
          : palette.uiFontFamily,
    );
    final field = TextField(
      controller: _textController,
      enabled: widget.enabled,
      maxLines: widget.multiLine ? 5 : 1,
      minLines: widget.multiLine ? 3 : 1,
      inputFormatters: widget.formatters,
      keyboardType: widget.keyboardType,
      style: style,
      cursorColor: palette.text,
      cursorWidth: 1,
      decoration: InputDecoration(
        isCollapsed: true,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 6.0,
          horizontal: 4.0,
        ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintText: widget.hint,
        hintStyle: TextStyle(
          color: palette.mutedText,
          fontSize: palette.bodyFontSize,
          fontFamily: palette.uiFontFamily,
        ),
        fillColor: Colors.transparent,
        filled: false,
      ),
    );
    return _Field(
      enabled: widget.enabled,
      child: Row(
        children: [
          if (widget.prefix != null)
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: widget.prefix,
            ),
          Expanded(child: field),
          if (widget.suffix != null) widget.suffix!,
        ],
      ),
    );
  }
}

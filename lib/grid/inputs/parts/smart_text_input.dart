part of '../column_input.dart';

enum _SmartKind { auto, plain, email, phone, url }

class _SmartTextInput extends StatefulWidget {
  final String? value;
  final bool enabled;
  final bool multiLine;
  final ValueChanged<Object?> onChanged;

  const _SmartTextInput({
    required this.value,
    required this.enabled,
    required this.multiLine,
    required this.onChanged,
  });

  @override
  State<_SmartTextInput> createState() => _SmartTextInputState();
}

class _SmartTextInputState extends State<_SmartTextInput> {
  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _phone = RegExp(r'^\+?[\d\s\-()]{7,}$');
  static final _url = RegExp(r'^https?://\S+$');

  _SmartKind _override = _SmartKind.auto;

  _SmartKind _detect(String s) {
    if (s.isEmpty) return _SmartKind.plain;
    if (_email.hasMatch(s)) return _SmartKind.email;
    if (_url.hasMatch(s)) return _SmartKind.url;
    if (_phone.hasMatch(s)) return _SmartKind.phone;
    return _SmartKind.plain;
  }

  _SmartKind get _effective {
    if (_override != _SmartKind.auto) return _override;
    return _detect(widget.value ?? '');
  }

  Widget? _iconFor(_SmartKind kind) {
    switch (kind) {
      case _SmartKind.email:
        return const Icon(Icons.alternate_email, size: 14);
      case _SmartKind.phone:
        return const Icon(Icons.call, size: 14);
      case _SmartKind.url:
        return const Icon(Icons.link, size: 14);
      case _SmartKind.plain:
      case _SmartKind.auto:
        return null;
    }
  }

  String _labelFor(_SmartKind kind) {
    switch (kind) {
      case _SmartKind.auto:
        return 'Auto';
      case _SmartKind.plain:
        return 'Plain';
      case _SmartKind.email:
        return 'Email';
      case _SmartKind.phone:
        return 'Phone';
      case _SmartKind.url:
        return 'URL';
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _effective;
    final icon = _iconFor(kind);
    final keyboard = switch (kind) {
      _SmartKind.email => TextInputType.emailAddress,
      _SmartKind.phone => TextInputType.phone,
      _SmartKind.url => TextInputType.url,
      _ => widget.multiLine ? TextInputType.multiline : TextInputType.text,
    };
    return _RawTextInput(
      value: widget.value,
      enabled: widget.enabled,
      multiLine: widget.multiLine,
      keyboardType: keyboard,
      prefix: icon == null
          ? null
          : Tooltip(
              message: 'Detected: ${_labelFor(kind)}',
              child: icon,
            ),
      suffix: widget.enabled
          ? _SmartKindMenu(
              current: _override,
              detected: _detect(widget.value ?? ''),
              labelFor: _labelFor,
              onSelected: (k) => setState(() => _override = k),
            )
          : null,
      onChanged: widget.onChanged,
    );
  }
}

class _SmartKindMenu extends StatelessWidget {
  final _SmartKind current;
  final _SmartKind detected;
  final String Function(_SmartKind) labelFor;
  final ValueChanged<_SmartKind> onSelected;

  const _SmartKindMenu({
    required this.current,
    required this.detected,
    required this.labelFor,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopupMenuButton<_SmartKind>(
      tooltip: 'Field kind',
      icon: Icon(Icons.tune, size: 14, color: palette.text),
      padding: EdgeInsets.zero,
      iconSize: 14,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final k in _SmartKind.values)
          PopupMenuItem(
            value: k,
            height: 26,
            child: Row(
              children: [
                Icon(
                  k == current ? Icons.check : Icons.circle_outlined,
                  size: 12,
                  color: k == current ? palette.accent : palette.border,
                ),
                const SizedBox(width: 6),
                Text(labelFor(k)),
                if (k == _SmartKind.auto)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '(${labelFor(detected)})',
                      style: TextStyle(
                        color: palette.mutedText,
                        fontSize: palette.smallFontSize,
                        fontFamily: palette.uiFontFamily,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

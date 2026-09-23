import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:code_field/material.dart';

import 'palette.dart';

/// Convenience language identifiers used across the host app. The widget
/// itself accepts any string the underlying grammar registry knows about
/// — these constants are the ones dbscope uses most often, surfaced so
/// callers don't sprinkle string literals.
class CodeLanguages {
  CodeLanguages._();

  static const String json = SyntaxLanguages.json;
  static const String sql = SyntaxLanguages.sql;
  static const String dart = SyntaxLanguages.dart;
  static const String markdown = SyntaxLanguages.markdown;
}

/// Build a [SyntaxTheme] from an [AppPalette]. The mapping reuses the
/// palette's `type*` roles so JSON/SQL/etc. highlight in the same colours
/// the data grid uses for typed cells — strings look like strings,
/// numbers look like numbers, etc.
SyntaxTheme syntaxThemeFromPalette(AppPalette palette) {
  return <String, TextStyle>{
    'comment': TextStyle(color: palette.mutedText, fontStyle: FontStyle.italic),
    'keyword': TextStyle(color: palette.accent, fontWeight: FontWeight.w600),
    'literal': TextStyle(color: palette.typeBool),
    'number': TextStyle(color: palette.typeNumber),
    'string': TextStyle(color: palette.typeString),
    'type': TextStyle(color: palette.typeJson),
    'class': TextStyle(color: palette.typeJson),
    'function': TextStyle(color: palette.accent),
    'meta': TextStyle(color: palette.mutedText),
    'tag': TextStyle(color: palette.accent),
    'attr': TextStyle(color: palette.typeJson),
    'variable': TextStyle(color: palette.typeString),
    'built_in': TextStyle(color: palette.typeJson),
    'selector-tag': TextStyle(color: palette.accent),
    'section': TextStyle(color: palette.accent, fontWeight: FontWeight.w600),
    'strong': const TextStyle(fontWeight: FontWeight.bold),
    'emphasis': const TextStyle(fontStyle: FontStyle.italic),
    'code': TextStyle(
      color: palette.typeString,
      fontFamily: palette.monoFontFamily,
    ),
    'link': TextStyle(
      color: palette.accent,
      decoration: TextDecoration.underline,
    ),
  };
}

/// Reusable code viewer / inline editor. Drives every "show or edit a
/// blob of code" surface in the app — JSON cells, SQL editors, log
/// panels, anywhere syntax-highlighted text belongs.
///
/// Wraps `code_field` with a [SyntaxHighlightPlugin] and
/// resolves its default theme from the ambient [AppPalette]. Stays
/// framework-neutral in the sense that any [TextStyle] / [SyntaxTheme]
/// can be passed in to override the defaults.
///
/// Single-line + readOnly = the right shape for a data-grid cell. Multi-
/// line + editable = the right shape for the editor panel inside a
/// dialog or a subwindow.
class CodeViewer extends StatefulWidget {
  const CodeViewer({
    super.key,
    this.initialText = '',
    this.controller,
    required this.language,
    this.theme,
    this.readOnly = false,
    this.maxLines,
    this.minLines,
    this.expands = false,
    this.padding = const EdgeInsets.all(8),
    this.background,
    this.borderColor,
    this.borderRadius,
    this.style,
    this.scrollController,
    this.scrollPhysics,
    this.autofocus = false,
    this.onChanged,
    this.onTap,
    this.leading,
    this.trailing,
  }) : assert(
         controller != null || initialText != null,
         'Either controller or initialText must be supplied.',
       );

  /// Initial text. Ignored when [controller] is non-null.
  final String? initialText;

  /// Optional externally-owned controller. When null, [CodeViewer]
  /// creates and owns one. The controller carries plugin state, so
  /// re-using the same instance preserves selection across rebuilds.
  final InteractiveTextController? controller;

  /// Language id (one of [CodeLanguages.*] or any string the underlying
  /// [GrammarRegistry.defaults] knows about). Pass `null` (via the
  /// override `CodeViewer.plain`) to disable highlighting.
  final String language;

  /// Override the syntax theme. When null, defaults to
  /// [syntaxThemeFromPalette].
  final SyntaxTheme? theme;

  final bool readOnly;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final EdgeInsetsGeometry padding;

  /// Background colour. When null, defaults to `palette.field`.
  final Color? background;

  /// Border colour. When null, defaults to `palette.border`.
  final Color? borderColor;

  /// Corner radius. When null, defaults to `palette.cornerRadius`.
  final BorderRadiusGeometry? borderRadius;

  /// Base text style. When null, defaults to a monospace style derived
  /// from `palette.monoFontFamily` + `palette.bodyFontSize`.
  final TextStyle? style;

  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final GestureTapCallback? onTap;

  /// Optional leading widget (icon, label, status). See
  /// [InteractiveTextField.leading].
  final Widget? leading;

  /// Optional trailing widget (action button, dropdown trigger). See
  /// [InteractiveTextField.trailing].
  final Widget? trailing;

  @override
  State<CodeViewer> createState() => _CodeViewerState();
}

class _CodeViewerState extends State<CodeViewer> {
  InteractiveTextController? _ownedController;
  SyntaxHighlightPlugin? _plugin;

  InteractiveTextController get _controller =>
      widget.controller ?? (_ownedController ??= _createOwnedController());

  InteractiveTextController _createOwnedController() {
    final c = InteractiveTextController(text: widget.initialText ?? '');
    return c;
  }

  @override
  void didUpdateWidget(covariant CodeViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _ownedController?.dispose();
      _ownedController = null;
      _plugin = null;
    }
    if (widget.language != oldWidget.language) {
      _plugin?.language = widget.language;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _ensurePlugin(SyntaxTheme theme) {
    final existing = _controller.findPlugin<SyntaxHighlightPlugin>();
    if (existing != null) {
      existing.language = widget.language;
      existing.theme = theme;
      _plugin = existing;
      return;
    }
    final plugin = SyntaxHighlightPlugin(
      language: widget.language,
      theme: theme,
    );
    _controller.addPlugin(plugin);
    _plugin = plugin;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = widget.theme ?? syntaxThemeFromPalette(palette);
    _ensurePlugin(theme);

    final baseStyle =
        widget.style ??
        TextStyle(
          fontFamily: palette.monoFontFamily,
          fontSize: palette.bodyFontSize,
          color: palette.text,
          height: 1.3,
        );

    final radius =
        widget.borderRadius ?? BorderRadius.circular(palette.cornerRadius);
    final decoration = BoxDecoration(
      color: widget.background ?? palette.field,
      borderRadius: radius,
      border: Border.all(color: widget.borderColor ?? palette.border),
    );

    return MaterialInteractiveTextField(
      controller: _controller,
      style: baseStyle,
      readOnly: widget.readOnly,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      expands: widget.expands,
      padding: widget.padding,
      decoration: decoration,
      scrollController: widget.scrollController,
      scrollPhysics: widget.scrollPhysics,
      autofocus: widget.autofocus,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: widget.onChanged,
      onTap: widget.onTap,
      leading: widget.leading,
      trailing: widget.trailing,
    );
  }
}

/// Result returned by [showCodeEditorDialog].
@immutable
class CodeEditorResult {
  const CodeEditorResult({required this.text});
  final String text;
}

/// Optional validation hook used by [CodeEditorPanel] / dialogs.
/// Return null when the text is acceptable; return a short error message
/// to show in the panel footer otherwise. The Save button is disabled
/// while the error is non-null.
typedef CodeValidator = String? Function(String text);

/// Optional transform applied by the "Format" action and on Save. Common
/// uses: pretty-print + compact JSON, normalize SQL whitespace.
typedef CodeFormatter = String Function(String text);

/// Full-screen editor body. Used both inside the [showCodeEditorDialog]
/// dialog and (later) inside a `desktop_multi_window` subwindow. Owns
/// its own controller and re-validates on every change.
class CodeEditorPanel extends StatefulWidget {
  const CodeEditorPanel({
    super.key,
    required this.initialText,
    required this.language,
    this.validator,
    this.formatter,
    this.placeholder,
    this.theme,
    this.style,
    this.padding = const EdgeInsets.all(8),
    this.background,
    this.borderColor,
    this.borderRadius,
    this.autofocus = true,
    this.onChanged,
    this.onSaveRequested,
    this.onCancelRequested,
  });

  final String initialText;
  final String language;
  final CodeValidator? validator;
  final CodeFormatter? formatter;
  final String? placeholder;
  final SyntaxTheme? theme;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;
  final Color? background;
  final Color? borderColor;
  final BorderRadiusGeometry? borderRadius;
  final bool autofocus;

  /// Notified on every text change. The latest text is also accessible
  /// via [CodeEditorPanelController.text] when an external controller
  /// is wired up.
  final ValueChanged<String>? onChanged;

  /// Called when the user presses Cmd/Ctrl+S or any host-supplied Save
  /// affordance. Receives the current (validated) text.
  final ValueChanged<String>? onSaveRequested;

  /// Called when the user presses Esc.
  final VoidCallback? onCancelRequested;

  @override
  State<CodeEditorPanel> createState() => CodeEditorPanelState();
}

class CodeEditorPanelState extends State<CodeEditorPanel> {
  late final InteractiveTextController _controller;
  String? _error;

  /// Read-only access to the current text. Useful for hosts that drive
  /// Save from outside (e.g. dialog footer button).
  String get text => _controller.text;

  /// True when the current text has no validation error.
  bool get isValid => _error == null;

  /// The current error message, if any.
  String? get error => _error;

  @override
  void initState() {
    super.initState();
    _controller = InteractiveTextController(text: widget.initialText);
    _controller.addListener(_handleChange);
    _validate(widget.initialText);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleChange);
    _controller.dispose();
    super.dispose();
  }

  void _handleChange() {
    _validate(_controller.text);
    widget.onChanged?.call(_controller.text);
  }

  void _validate(String text) {
    final v = widget.validator;
    final next = v == null ? null : v(text);
    if (next != _error) setState(() => _error = next);
  }

  /// Format the current text via [CodeEditorPanel.formatter], if set.
  void format() {
    final f = widget.formatter;
    if (f == null) return;
    final next = f(_controller.text);
    if (next == _controller.text) return;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  /// Replace the current text. Useful for "Revert" / external sync.
  void setText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onSaveShortcut() {
    if (!isValid) return;
    widget.onSaveRequested?.call(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape): const _CancelIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            const _SaveIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            const _SaveIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) {
              widget.onCancelRequested?.call();
              return null;
            },
          ),
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              _onSaveShortcut();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CodeViewer(
                  controller: _controller,
                  language: widget.language,
                  theme: widget.theme,
                  style: widget.style,
                  padding: widget.padding,
                  background: widget.background,
                  borderColor: widget.borderColor,
                  borderRadius: widget.borderRadius,
                  maxLines: null,
                  expands: true,
                  autofocus: widget.autofocus,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: palette.smallFontSize,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// Material dialog wrapping a [CodeEditorPanel]. Returns the saved text
/// or null if cancelled. Web-safe — uses only [showDialog] and the
/// Flutter overlay system, no platform window APIs.
///
/// Hosts that want a desktop subwindow on IO can switch the launcher
/// instead of replacing this dialog — the dialog stays as the
/// always-available fallback.
Future<String?> showCodeEditorDialog(
  BuildContext context, {
  required String title,
  required String initialText,
  required String language,
  CodeValidator? validator,
  CodeFormatter? formatter,
  String? saveLabel,
  String? cancelLabel,
  String? formatLabel,
  double width = 640,
  double height = 460,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return _CodeEditorDialog(
        title: title,
        initialText: initialText,
        language: language,
        validator: validator,
        formatter: formatter,
        saveLabel: saveLabel ?? 'Save',
        cancelLabel: cancelLabel ?? 'Cancel',
        formatLabel: formatLabel,
        width: width,
        height: height,
      );
    },
  );
}

class _CodeEditorDialog extends StatefulWidget {
  const _CodeEditorDialog({
    required this.title,
    required this.initialText,
    required this.language,
    required this.validator,
    required this.formatter,
    required this.saveLabel,
    required this.cancelLabel,
    required this.formatLabel,
    required this.width,
    required this.height,
  });

  final String title;
  final String initialText;
  final String language;
  final CodeValidator? validator;
  final CodeFormatter? formatter;
  final String saveLabel;
  final String cancelLabel;
  final String? formatLabel;
  final double width;
  final double height;

  @override
  State<_CodeEditorDialog> createState() => _CodeEditorDialogState();
}

class _CodeEditorDialogState extends State<_CodeEditorDialog> {
  final GlobalKey<CodeEditorPanelState> _panelKey =
      GlobalKey<CodeEditorPanelState>();
  bool _isValid = true;

  void _save() {
    final state = _panelKey.currentState;
    if (state == null || !state.isValid) return;
    Navigator.of(context).pop(state.text);
  }

  void _cancel() => Navigator.of(context).pop();

  void _format() => _panelKey.currentState?.format();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CodeEditorPanel(
          key: _panelKey,
          initialText: widget.initialText,
          language: widget.language,
          validator: widget.validator,
          formatter: widget.formatter,
          onChanged: (_) {
            final v = _panelKey.currentState?.isValid ?? true;
            if (v != _isValid) setState(() => _isValid = v);
          },
          onSaveRequested: (_) => _save(),
          onCancelRequested: _cancel,
        ),
      ),
      actions: [
        if (widget.formatter != null)
          TextButton(
            onPressed: _format,
            child: Text(widget.formatLabel ?? 'Format'),
          ),
        TextButton(onPressed: _cancel, child: Text(widget.cancelLabel)),
        FilledButton(
          onPressed: _isValid ? _save : null,
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}

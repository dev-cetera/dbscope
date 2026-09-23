import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:highlight/languages/sql.dart';

class SqlEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRun;
  final bool readOnly;

  const SqlEditor({
    super.key,
    required this.initialText,
    required this.onChanged,
    this.onRun,
    this.readOnly = false,
  });

  @override
  State<SqlEditor> createState() => _SqlEditorState();
}

class _SqlEditorState extends State<SqlEditor> {
  late final CodeController _controller;

  // flutter_code_editor's CodeController.analyzeCode runs an async pass
  // on every text change and on initial mount, then notifies listeners.
  // The CodeField listens to the same controller and reads
  // `localToGlobal` from inside its `_onTextChanged` to position the
  // autocomplete popup — if our `addListener` callback runs *before*
  // the CodeField has been laid out, the popup positioning hits an
  // unlaid RenderBox and throws "RenderBox was not laid out". Wiring
  // the onChanged listener after the first frame avoids that race.
  void _onControllerChanged() {
    if (!mounted) return;
    widget.onChanged(_controller.text);
  }

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: widget.initialText,
      language: sql,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.addListener(_onControllerChanged);
    });
  }

  @override
  void didUpdateWidget(covariant SqlEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialText != widget.initialText &&
        widget.initialText != _controller.text) {
      _controller.text = widget.initialText;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            const _RunIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _RunIntent(),
      },
      child: Actions(
        actions: {
          _RunIntent: CallbackAction<_RunIntent>(
            onInvoke: (_) {
              widget.onRun?.call();
              return null;
            },
          ),
        },
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.dividerColor),
          ),
          child: CodeField(
            controller: _controller,
            readOnly: widget.readOnly,
            textStyle: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
            background: theme.colorScheme.surfaceContainerLow,
            gutterStyle: GutterStyle(
              showLineNumbers: true,
              textStyle: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                color: theme.hintColor,
              ),
              background: theme.colorScheme.surfaceContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _RunIntent extends Intent {
  const _RunIntent();
}

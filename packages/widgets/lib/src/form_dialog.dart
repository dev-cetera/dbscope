import 'package:flutter/material.dart';

/// Shared scaffold for the app's modal dialogs.
///
/// Every dialog in the app follows the same shape: a fixed-width
/// [AlertDialog] with a title, a scrolling/intrinsic content body, and a
/// Cancel/Submit pair in the actions row. [AppFormDialog] collapses that
/// boilerplate into one widget so call sites only describe the body and
/// the submit handler.
///
/// Pass [onSubmit] = null to render the submit button as disabled (e.g.
/// when a required field is unset). Pass [submitLabel] = null to drop
/// the submit button entirely — useful for picker-style dialogs whose
/// only "submit" is a row tap inside the body.
class AppFormDialog extends StatelessWidget {
  /// Dialog title text. Rendered with the theme's titleMedium style.
  final String title;

  /// Body of the dialog. Wrapped in a `SizedBox(width: [width])`. If
  /// [scrollable] is true (default), wrapped in `SingleChildScrollView`
  /// too — set false for bodies that already own their own scrolling
  /// (e.g. an `Expanded` + `ListView`).
  final Widget content;

  /// Fixed body width. 460 is the default we've used everywhere; pick
  /// something smaller for compact pickers.
  final double width;

  /// Optional fixed body height. Use for pickers/lists that need a
  /// bounded scroll region; leave null for forms that should size to
  /// their content.
  final double? height;

  /// True (default): body is wrapped in `SingleChildScrollView`. Set to
  /// false when the body owns its own scrolling.
  final bool scrollable;

  /// Submit handler. When null the submit button renders disabled.
  /// Ignored when [submitLabel] is null.
  final VoidCallback? onSubmit;

  /// Submit button label. Set to null to drop the submit button.
  final String? submitLabel;

  /// Optional icon to show next to the submit label.
  final IconData? submitIcon;

  /// Cancel button label. Defaults to "Cancel".
  final String cancelLabel;

  /// Optional extra actions inserted between Cancel and Submit.
  final List<Widget> extraActions;

  const AppFormDialog({
    super.key,
    required this.title,
    required this.content,
    this.width = 460,
    this.height,
    this.scrollable = true,
    this.onSubmit,
    this.submitLabel = 'OK',
    this.submitIcon,
    this.cancelLabel = 'Cancel',
    this.extraActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final body = scrollable ? SingleChildScrollView(child: content) : content;
    final submitButton =
        submitLabel == null
            ? null
            : (submitIcon == null
                ? FilledButton(onPressed: onSubmit, child: Text(submitLabel!))
                : FilledButton.icon(
                  onPressed: onSubmit,
                  icon: Icon(submitIcon, size: 16),
                  label: Text(submitLabel!),
                ));
    return AlertDialog(
      title: Text(title),
      content: SizedBox(width: width, height: height, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(cancelLabel),
        ),
        ...extraActions,
        if (submitButton != null) submitButton,
      ],
    );
  }
}

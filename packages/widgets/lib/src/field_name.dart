import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Gives a text field a name that macOS accessibility clients can read.
///
/// Flutter on macOS hands each text field to the system as a native field
/// and drops its label (`labelText`, `hintText`, a `Semantics` label), so
/// VoiceOver, or an agent driving the app through accessibility, sees an
/// unnamed box. This adds [name] as a text node covering the field, read
/// just before it, and clicking that text lands in the field.
///
/// Elsewhere the field's own label already reaches the platform, so this
/// adds nothing there.
class FieldName extends StatelessWidget {
  const FieldName(this.name, {super.key, required this.child});

  final String name;

  /// The text field, usually a `TextField` or `TextFormField`.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return child;
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            container: true,
            label: name,
            child: const SizedBox.expand(),
          ),
        ),
        child,
      ],
    );
  }
}

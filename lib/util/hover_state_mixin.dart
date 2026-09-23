import 'package:flutter/widgets.dart';

/// Mixin for the `bool _hovered` + onEnter/onExit pattern that appears
/// in every tab-strip widget, the new-tab button, and similar
/// hover-styled affordances. Use:
///
/// ```dart
/// class _MyWidgetState extends State<_MyWidget> with HoverStateMixin {
/// @override
/// Widget build(BuildContext context) {
/// return MouseRegion(
/// onEnter: (_) => setHovered(true),
/// onExit: (_) => setHovered(false),
/// child: ...,
/// );
/// }
/// }
/// ```
mixin HoverStateMixin<T extends StatefulWidget> on State<T> {
  bool _hovered = false;

  bool get isHovered => _hovered;

  void setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }
}

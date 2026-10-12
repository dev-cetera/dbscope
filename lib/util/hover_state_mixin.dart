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
/// onEnter: (_) => setHovered(hovered: true),
/// onExit: (_) => setHovered(hovered: false),
/// child: ...,
/// );
/// }
/// }
/// ```
mixin HoverStateMixin<T extends StatefulWidget> on State<T> {
  var _hovered = false;

  bool get isHovered => _hovered;

  void setHovered({required bool hovered}) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
  }
}

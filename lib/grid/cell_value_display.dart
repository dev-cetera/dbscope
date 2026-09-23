import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../shell/app_state.dart';
import 'json_dialogs.dart';
import 'typed_value_text.dart';

export 'json_dialogs.dart' show showJsonEditorDialog, jsonSourceOf;

/// "Display a value" used by every place in the app that shows one
/// row's data: the data grid in display mode, the PropertyInspector
/// row, and any future read-only views. One widget, one rendering
/// pipeline — the goal is that "the email column shows the same thing
/// in the grid as in the inspector," and adding a new affordance
/// happens in exactly one place.
///
/// Affordances:
///
/// - URL / email / phone detection (delegated to [TypedValueText]).
/// - Per-PG-type color (delegated to [TypedValueText]).
/// - Link icon when the column is a PK (with inbound references) or
/// an outbound FK. Tap opens a popup menu listing every linkable
/// target — caller handles navigation.
/// - JSON expand icon when the column is `json`/`jsonb` and the value
/// is non-null. Tap opens a pretty-printed read-only viewer.
///
/// All affordance icons fit on the trailing edge of the cell; if
/// there isn't room (very narrow column), they overlap the text. The
/// PropertyInspector renders the same affordances in the same order.
class CellValueDisplay extends StatelessWidget {
  final Object? value;
  final PgType pgType;
  final String columnName;

  /// FK in which this column is the *from* side (the local column).
  /// Used to surface "Open referenced row in `<target table>`".
  /// Null means the column is not an outbound FK.
  final ForeignKey? outboundFk;

  /// FKs in which this column is the *to* side (i.e. other tables
  /// reference this PK column). Used to surface "Open rows in
  /// `<from table>` that reference this".
  final List<ForeignKey> inboundRefs;

  /// Tap callback for a link target. `incoming = true` means the user
  /// picked an inbound reference (rows that point at this PK);
  /// `incoming = false` means an outbound FK (row this column points
  /// at). The caller decides what "navigate" means (open Navigator,
  /// push step, etc.).
  final void Function(ForeignKey fk, bool incoming)? onFollowLink;

  /// When true the type-derived color is applied. When false the
  /// widget renders in the palette's text color (matches the grid's
  /// `GridViewMode.table` look). Defaults true.
  final bool colored;

  /// When true (default), URLs / emails / phones inside text are
  /// underlined and tap-launchable.
  final bool detectUrl;

  const CellValueDisplay({
    super.key,
    required this.value,
    required this.pgType,
    required this.columnName,
    this.outboundFk,
    this.inboundRefs = const [],
    this.onFollowLink,
    this.colored = true,
    this.detectUrl = true,
  });

  bool get _isJson => pgType == PgType.json || pgType == PgType.jsonb;
  bool get _hasLink =>
      onFollowLink != null && (outboundFk != null || inboundRefs.isNotEmpty);
  bool get _hasJsonExpand => _isJson && value != null;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = TypedValueText(
      value: value,
      pgType: pgType,
      colorOverride: colored ? null : palette.text,
      detectUrl: detectUrl,
    );
    if (!_hasLink && !_hasJsonExpand) return text;
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: text),
        if (_hasLink)
          _LinkButton(
            outboundFk: outboundFk,
            inboundRefs: inboundRefs,
            onFollow: onFollowLink!,
            accent: palette.accent,
          ),
        if (_hasJsonExpand)
          _JsonExpandButton(
            value: value,
            columnName: columnName,
            color: palette.typeJson,
          ),
      ],
    );
  }
}

class _LinkButton extends StatelessWidget {
  final ForeignKey? outboundFk;
  final List<ForeignKey> inboundRefs;
  final void Function(ForeignKey fk, bool incoming) onFollow;
  final Color accent;

  const _LinkButton({
    required this.outboundFk,
    required this.inboundRefs,
    required this.onFollow,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return _IconButton(
      tooltip: 'Linked rows',
      icon: Icons.link,
      color: accent,
      onPressed: () => _showMenu(context),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    final items = <PopupMenuEntry<_LinkChoice>>[];
    if (outboundFk != null) {
      items.add(
        PopupMenuItem(
          value: _LinkChoice(outboundFk!, incoming: false),
          child: Row(
            children: [
              const Icon(Icons.east, size: 14),
              const SizedBox(width: 6),
              Text(
                'Open row in ${outboundFk!.toSchema}.${outboundFk!.toTable}',
              ),
            ],
          ),
        ),
      );
    }
    if (inboundRefs.isNotEmpty) {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      items.add(
        const PopupMenuItem(
          enabled: false,
          height: 24,
          child: Text(
            'REFERENCED BY',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
          ),
        ),
      );
      for (final fk in inboundRefs) {
        items.add(
          PopupMenuItem(
            value: _LinkChoice(fk, incoming: true),
            child: Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${fk.fromSchema}.${fk.fromTable}.${fk.fromColumn}',
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    if (items.isEmpty) return;
    final choice = await showMenu<_LinkChoice>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + size.height,
        pos.dx + size.width,
        pos.dy + size.height + 1,
      ),
      items: items,
    );
    if (choice != null) onFollow(choice.fk, choice.incoming);
  }
}

class _LinkChoice {
  final ForeignKey fk;
  final bool incoming;
  const _LinkChoice(this.fk, {required this.incoming});
}

class _JsonExpandButton extends StatelessWidget {
  final Object? value;
  final String columnName;
  final Color color;

  const _JsonExpandButton({
    required this.value,
    required this.columnName,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return _IconButton(
      tooltip: 'View JSON',
      icon: Icons.data_object,
      color: color,
      onPressed: () => _show(context),
    );
  }

  Future<void> _show(BuildContext context) async {
    final raw = value;
    if (raw == null) return;
    final source = jsonSourceOf(raw);
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent(' ').convert(jsonDecode(source));
    } catch (_) {
      pretty = source;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => JsonViewerDialog(
        columnName: columnName,
        pretty: pretty,
        // Tab spawning lives at this layer (the cell display) because
        // the dialog widget itself stays decoupled from AppState.
        onOpenInNewTab: () {
          final connId = ConnectionRegistry.instance.activeId;
          if (connId == null) return;
          AppState.instance.openJsonTab(
            connectionId: connId,
            columnName: columnName,
            content: pretty,
          );
        },
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  const _IconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 12,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Icon(icon, size: 12, color: color),
        ),
      ),
    );
  }
}

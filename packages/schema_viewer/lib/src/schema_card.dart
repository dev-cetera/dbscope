import 'package:flutter/material.dart';

import 'schema_layout.dart';
import 'schema_model.dart';
import 'table_colors.dart';
import 'type_colors.dart';

/// The one card the schema viewer renders. Visually deliberate enough
/// that the host app can drop it into a full ER diagram, a single-row
/// linked explorer, or a side-panel preview without restyling.
///
/// State surface beyond plain idle (mirrors admin_site's TableNode):
/// * `isSelected || isHighlighted` — both get the "highlighted" look:
/// 2-px primary outline, a white outer ring + deeper shadow. The
/// selected card and its FK neighbours look the same so the
/// connected subgraph reads as one cluster.
/// * `hasSelection && !isHighlighted && !isSelected` — dimmed to
/// 35% opacity so the highlighted cluster pops.
///
/// `value` rendering: when [SchemaFieldSpec.valueDisplay] is non-null
/// the right column of the row shows that string (muted when
/// [SchemaFieldSpec.valueIsNull] is set) instead of the static type
/// label. That's how a host can show live row data on the same card.
class SchemaCard extends StatelessWidget {
  final SchemaNodeData node;
  final bool isSelected;
  final bool isHighlighted;
  final bool hasSelection;

  /// Tap on the card body. Hosts typically wire this to
  /// "selectedId = node.id" — single-click selection.
  final VoidCallback? onTap;

  /// Header pan gesture handlers — passed through so the canvas can
  /// drive drag/move without the card knowing it's on a Stack.
  final VoidCallback? onHeaderPanStart;
  final void Function(DragUpdateDetails details)? onHeaderPanUpdate;
  final VoidCallback? onHeaderPanEnd;
  final void Function(Offset globalPosition)? onSecondaryTapDown;

  /// Toggle compact mode (PK/FK-only fields). When null, the
  /// compact-toggle button is hidden — a host that always wants the
  /// full schema can leave this off.
  final VoidCallback? onToggleCompact;

  /// "Drill-in" action triggered by the header's open-in-new button.
  /// Hosts wire this to opening their inspector / table view / row
  /// detail / whatever the right answer is for this card. When null
  /// the button is hidden.
  final VoidCallback? onActivate;

  /// Custom tooltip for the activate button. Defaults to "Open".
  final String activateTooltip;

  /// Custom icon for the activate button. Defaults to
  /// [Icons.open_in_new].
  final IconData activateIcon;

  const SchemaCard({
    super.key,
    required this.node,
    this.isSelected = false,
    this.isHighlighted = false,
    this.hasSelection = false,
    this.onTap,
    this.onHeaderPanStart,
    this.onHeaderPanUpdate,
    this.onHeaderPanEnd,
    this.onSecondaryTapDown,
    this.onToggleCompact,
    this.onActivate,
    this.activateTooltip = 'Open',
    this.activateIcon = Icons.open_in_new,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkMode = theme.brightness == Brightness.dark;
    // admin_site treats selection + neighbours identically: both get
    // the "highlighted" frame. Dimming applies only when something
    // else is the highlighted cluster.
    final highlighted = isSelected || isHighlighted;
    final dimmed = hasSelection && !highlighted;
    final headerColor = colorForTable('${node.schema}.${node.tableName}');
    final visibleFields = <SchemaFieldSpec>[
      for (final f in node.fields)
        if (!node.compact || f.pk || f.fk || f.isRefTarget) f,
    ];
    // admin_site uses 2px primary outline when highlighted, otherwise
    // the theme's neutral border (theme.border, solid). With
    // `strokeAlign: BorderSide.strokeAlignOutside` the border draws
    // OUTSIDE the layout rect — same effect as CSS content-box where
    // the border grows outward, and zero inner-space cost so the
    // Column inside the AnimatedContainer doesn't overflow by
    // `borderWidth × 2` pixels. (Default strokeAlignInside would
    // claim borderWidth of every inner edge.)
    final borderColor =
        highlighted ? theme.colorScheme.primary : theme.colorScheme.outline;
    final borderWidth = highlighted ? 2.0 : 1.0;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeInOut,
      opacity: dimmed ? 0.35 : 1.0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: borderColor,
            width: borderWidth,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
          boxShadow: highlighted
              ? [
                  // admin_site: 0 0 0 1px white-0.4 (outer ring) +
                  // 0 4px 14px black-0.45 (drop shadow).
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.4),
                    blurRadius: 0,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  // admin_site default: 0 2px 8px black-0.35.
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SchemaCardHeader(
              node: node,
              headerColor: headerColor,
              onTap: onTap,
              onHeaderPanStart: onHeaderPanStart,
              onHeaderPanUpdate: onHeaderPanUpdate,
              onHeaderPanEnd: onHeaderPanEnd,
              onSecondaryTapDown: onSecondaryTapDown,
              onToggleCompact: onToggleCompact,
              onActivate: onActivate,
              activateTooltip: activateTooltip,
              activateIcon: activateIcon,
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onSecondaryTapDown: onSecondaryTapDown == null
                  ? null
                  : (d) => onSecondaryTapDown!(d.globalPosition),
              child: SizedBox(
                width: effectiveNodeWidth(node),
                child: visibleFields.isEmpty
                    ? const _EmptyBody()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final f in visibleFields)
                            _SchemaFieldRow(
                              field: f,
                              darkMode: darkMode,
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SchemaCardHeader extends StatelessWidget {
  final SchemaNodeData node;
  final Color headerColor;
  final VoidCallback? onTap;
  final VoidCallback? onHeaderPanStart;
  final void Function(DragUpdateDetails details)? onHeaderPanUpdate;
  final VoidCallback? onHeaderPanEnd;
  final void Function(Offset globalPosition)? onSecondaryTapDown;
  final VoidCallback? onToggleCompact;
  final VoidCallback? onActivate;
  final String activateTooltip;
  final IconData activateIcon;

  const _SchemaCardHeader({
    required this.node,
    required this.headerColor,
    required this.onTap,
    required this.onHeaderPanStart,
    required this.onHeaderPanUpdate,
    required this.onHeaderPanEnd,
    required this.onSecondaryTapDown,
    required this.onToggleCompact,
    required this.onActivate,
    required this.activateTooltip,
    required this.activateIcon,
  });

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(headerColor);
    // Pick a header foreground that contrasts cleanly against any
    // palette colour: white on dark hues, near-black on light ones.
    final onHeader = hsl.lightness < 0.55 ? Colors.white : Colors.black87;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onPanStart: onHeaderPanStart == null ? null : (_) => onHeaderPanStart!(),
      onPanUpdate: onHeaderPanUpdate,
      onPanEnd: onHeaderPanEnd == null ? null : (_) => onHeaderPanEnd!(),
      onPanCancel: onHeaderPanEnd,
      onSecondaryTapDown: onSecondaryTapDown == null
          ? null
          : (d) => onSecondaryTapDown!(d.globalPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Container(
          height: kSchemaHeaderHeight +
              (node.subtitle != null ? kSchemaSubtitleHeight : 0),
          // admin_site uses padding "0 12px"; the Column's centred
          // mainAxis handles vertical placement.
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: headerColor,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (node.headerLeadingIcon != null) ...[
                    Icon(node.headerLeadingIcon, size: 13, color: onHeader),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      node.tableName,
                      style: TextStyle(
                        color: onHeader,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  if (onActivate != null) ...[
                    const SizedBox(width: 6),
                    _HeaderButton(
                      tooltip: activateTooltip,
                      onHeaderColor: onHeader,
                      onPressed: onActivate!,
                      child: Icon(activateIcon, size: 12, color: onHeader),
                    ),
                  ],
                  if (onToggleCompact != null) ...[
                    const SizedBox(width: 6),
                    _HeaderButton(
                      tooltip: node.compact
                          ? 'Show all fields'
                          : 'Show only PKs and FKs',
                      onHeaderColor: onHeader,
                      onPressed: onToggleCompact!,
                      // admin_site renders the glyph as plain "+" or
                      // "-" text — keeps it crisp against the colored
                      // header at all theme palettes.
                      child: Text(
                        node.compact ? '+' : '-',
                        style: TextStyle(
                          color: onHeader,
                          fontSize: 14,
                          height: 1.0,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (node.subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    node.subtitle!,
                    style: TextStyle(
                      color: onHeader.withValues(alpha: 0.85),
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final String tooltip;
  final Color onHeaderColor;
  final VoidCallback onPressed;
  final Widget child;
  const _HeaderButton({
    required this.tooltip,
    required this.onHeaderColor,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          // Stop pan so the canvas doesn't start a drag when the user
          // clicks the open/expand affordance.
          onPanStart: (_) {},
          onTap: onPressed,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              // admin_site: bg = white-0.28, border = white-0.45, radius 3.
              color: Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.45),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: kSchemaEmptyBodyHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '(no PK/FK fields)',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              fontStyle: FontStyle.italic,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}

class _SchemaFieldRow extends StatelessWidget {
  final SchemaFieldSpec field;
  final bool darkMode;
  const _SchemaFieldRow({
    required this.field,
    required this.darkMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fkColor = field.fk && field.linkedTable != null
        ? colorForTable(field.linkedTable!)
        : null;
    // admin_site: FK rows tint with linkedTable color so the chain row
    // -> edge -> remote header reads as one colour. PK rows + plain
    // rows use theme.textOnDark (text-on-surface in Flutter).
    final nameColor = fkColor ?? theme.colorScheme.onSurface;
    final prefix = field.pk
        ? '* '
        : field.fk
            ? '+ '
            : '';
    final typeText = field.valueDisplay ?? field.typeLabel;
    final rightColor = field.valueDisplay != null
        ? (field.valueIsNull
            ? theme.colorScheme.onSurface.withValues(alpha: 0.45)
            : theme.colorScheme.onSurface.withValues(alpha: 0.85))
        : colorForType(field.typeLabel, darkMode: darkMode)
            .withValues(alpha: 0.95);
    // admin_site: borderTop is theme.border at 0x40 (25% alpha) — a
    // subtle hairline between rows.
    return Container(
      height: kSchemaRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.25),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$prefix${field.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: nameColor,
                fontWeight: field.pk ? FontWeight.w700 : FontWeight.w400,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            // admin_site clamps the type column at 110px so a long
            // type doesn't push the column name off-card.
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(
              typeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: rightColor,
                fontFamily: 'Menlo',
                fontSize: 11,
                fontStyle: field.valueIsNull ? FontStyle.italic : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

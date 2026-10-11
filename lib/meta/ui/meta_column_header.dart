// A grid column header that explains itself: hover shows the column's
// description (Markdown), right-click offers "About this column".
// Used through DataGrid.headerBuilder by the table and named-query grids.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../catalog/pg_type.dart';
import '../meta_cache.dart';
import 'description_tooltip.dart';
import 'meta_dialogs.dart';
import 'meta_menu.dart';

class MetaColumnHeader extends StatelessWidget {
  final MetaClickContext click;
  final Widget child;

  const MetaColumnHeader({super.key, required this.click, required this.child});

  /// A header of [schema].[table].[column].
  factory MetaColumnHeader.forTable({
    Key? key,
    required String connectionId,
    required String schema,
    required String table,
    required String column,
    PgType? columnType,
    required Widget child,
  }) => MetaColumnHeader(
    key: key,
    click: MetaClickContext(
      connectionId: connectionId,
      schema: schema,
      table: table,
      column: column,
      columnType: columnType,
    ),
    child: child,
  );

  /// A header of a named query's result [column].
  factory MetaColumnHeader.forQuery({
    Key? key,
    required String connectionId,
    required String queryId,
    required String column,
    PgType? columnType,
    required Widget child,
  }) => MetaColumnHeader(
    key: key,
    click: MetaClickContext(
      connectionId: connectionId,
      queryId: queryId,
      column: column,
      columnType: columnType,
    ),
    child: child,
  );

  String _markdown() {
    final index = MetadataCache.instance.snapshotFor(click.connectionId)?.index;
    final column = click.column;
    if (index == null || column == null) return '';
    final queryId = click.queryId;
    if (queryId != null) {
      return index.describeQueryColumn(queryId, column).toMarkdown();
    }
    return index
        .describeColumn(click.schema!, click.table!, column)
        .toMarkdown();
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final picked = await showAppContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        AppMenuEntry(
          value: 'about',
          label: 'About "${click.column}"…',
          icon: Icons.info_outline,
        ),
      ],
    );
    if (picked == 'about' && context.mounted) {
      await showAboutColumnDialog(context, click);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showMenu(context, details.globalPosition),
      child: DescriptionTooltip(markdown: _markdown(), child: child),
    );
  }
}

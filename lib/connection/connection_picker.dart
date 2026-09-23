import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../db/plugin.dart';
import 'profile.dart';

/// Show the connection wizard. If multiple kinds are registered, ask the
/// user which kind first; otherwise open the sole plugin's dialog. For
/// edit flows, [initial] forces the same kind that the profile was
/// created with.
Future<ConnectionProfile?> showAddConnectionDialog(
  BuildContext context, {
  ConnectionProfile? initial,
}) async {
  final registry = ConnectionKindRegistry.instance;
  if (initial != null) {
    final plugin = registry.lookup(initial.kind);
    if (plugin == null) return null;
    return plugin.showProfileDialog(context, initial: initial);
  }
  final kinds = registry.all;
  if (kinds.isEmpty) return null;
  // On native we short-circuit single-kind setups straight into the
  // sole plugin's dialog. On web we always show the picker so users
  // can see what backends exist (and learn that desktop-only kinds
  // like Postgres/SQLite aren't available here).
  if (!kIsWeb && kinds.length == 1) {
    return kinds.first.showProfileDialog(context);
  }
  final picked = await showDialog<ConnectionKindPlugin>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('New connection'),
      children: [
        for (final k in kinds)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(k),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(k.label),
            ),
          ),
      ],
    ),
  );
  if (picked == null) return null;
  if (!context.mounted) return null;
  return picked.showProfileDialog(context);
}

part of '../sidebar.dart';

class _ConnectionPicker extends StatelessWidget {
  final ConnectionRegistry registry;
  final Future<void> Function() onReload;

  const _ConnectionPicker({required this.registry, required this.onReload});

  Future<void> _openMenu(BuildContext context, Offset globalPos) async {
    // Pull a fresh list every time so a saved-from-another-window
    // connection shows up.
    await registry.reloadProfiles();
    if (!context.mounted) return;
    final profile = registry.profile;
    final profiles = registry.profiles;
    final items = <SearchableMenuItem<_PickerAction>>[
      for (final p in profiles)
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.switchTo, id: p.id),
          searchKey: p.name,
          child: Row(
            children: [
              Icon(
                p.id == registry.activeId
                    ? Icons.radio_button_on
                    : Icons.radio_button_off,
                size: 14,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ),
              if (p.readOnly)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text('RO', style: TextStyle(fontSize: 9)),
                ),
            ],
          ),
        ),
      const SearchableMenuItem<_PickerAction>(
        value: _PickerAction(_ActionKind.add),
        searchKey: 'add connection new',
        child: Row(
          children: [
            Icon(Icons.add, size: 16),
            SizedBox(width: 8),
            Text('Add connection…'),
          ],
        ),
      ),
      const SearchableMenuItem<_PickerAction>(
        value: _PickerAction(_ActionKind.refresh),
        searchKey: 'refresh list reload',
        child: Row(
          children: [
            Icon(Icons.refresh, size: 16),
            SizedBox(width: 8),
            Text('Refresh list'),
          ],
        ),
      ),
      if (profile != null) ...[
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.edit, id: profile.id),
          searchKey: 'edit current settings',
          child: const Row(
            children: [
              Icon(Icons.edit, size: 16),
              SizedBox(width: 8),
              Text('Edit current…'),
            ],
          ),
        ),
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.toggleRo, id: profile.id),
          searchKey: 'read-only readonly toggle',
          child: Row(
            children: [
              Icon(
                registry.isReadOnly ? Icons.lock_open : Icons.lock_outline,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(registry.isReadOnly ? 'Make read-write' : 'Make read-only'),
            ],
          ),
        ),
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.remove, id: profile.id),
          searchKey: 'remove delete current',
          child: const Row(
            children: [
              Icon(Icons.delete_outline, size: 16),
              SizedBox(width: 8),
              Text('Remove current'),
            ],
          ),
        ),
        const SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.disconnect),
          searchKey: 'disconnect',
          child: Row(
            children: [
              Icon(Icons.power_settings_new, size: 16),
              SizedBox(width: 8),
              Text('Disconnect'),
            ],
          ),
        ),
      ],
    ];
    final action = await showSearchableMenu<_PickerAction>(
      context: context,
      position: globalPos,
      items: items,
      hint: 'Find connection or action…',
    );
    if (action == null || !context.mounted) return;
    switch (action.kind) {
      case _ActionKind.switchTo:
        await registry.setActive(action.id, context: context);
        break;
      case _ActionKind.add:
        final created = await showAddConnectionDialog(context);
        if (created == null || !context.mounted) return;
        await registry.connectProfile(created, context: context);
        AppState.instance.notifyChange();
        break;
      case _ActionKind.edit:
        final p = registry.profileById(action.id!);
        if (p == null) return;
        final edited = await showAddConnectionDialog(context, initial: p);
        if (edited != null) {
          await registry.updateProfile(edited);
          if (!context.mounted) return;
          if (registry.activeId == edited.id) {
            await registry.killConnection(edited.id);
            if (!context.mounted) return;
            await registry.connectActive(context: context);
          }
        }
        break;
      case _ActionKind.remove:
        final p = registry.profileById(action.id!);
        if (p == null) return;
        final ok = await confirmDialog(
          context,
          title: 'Remove "${p.name}"?',
          message: 'Saved credentials will be deleted.',
          confirmLabel: 'Remove',
          destructive: true,
        );
        if (ok) {
          await registry.removeProfile(p.id);
          AppState.instance.closeTabsForConnection(p.id);
        }
        break;
      case _ActionKind.disconnect:
        await registry.disconnect();
        break;
      case _ActionKind.toggleRo:
        final p = registry.profileById(action.id!);
        if (p == null) return;
        await registry.setReadOnly(p.id, !registry.isReadOnly);
        break;
      case _ActionKind.refresh:
        await registry.reloadProfiles();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = registry.profile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            profile == null
                ? Icons.power_settings_new
                : (registry.isConnected
                      ? Icons.check_circle
                      : Icons.error_outline),
            size: 16,
            color: profile == null
                ? theme.hintColor
                : (registry.isConnected ? Colors.green : Colors.orange),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Builder(
              builder: (btnCtx) => InkWell(
                onTap: () {
                  final box = btnCtx.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final origin = box.localToGlobal(Offset(0, box.size.height));
                  _openMenu(btnCtx, origin);
                },
                child: Tooltip(
                  message: 'Connections',
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile == null ? 'no connection' : profile.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (registry.isConnecting)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (profile != null)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () async => onReload(),
            ),
        ],
      ),
    );
  }
}

enum _ActionKind { switchTo, add, edit, remove, disconnect, toggleRo, refresh }

class _PickerAction {
  final _ActionKind kind;
  final String? id;
  const _PickerAction(this.kind, {this.id});
}

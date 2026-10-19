part of '../sidebar.dart';

class _ConnectionPicker extends StatelessWidget {
  const _ConnectionPicker({required this.registry, required this.onReload});
  final ConnectionRegistry registry;
  final Future<void> Function() onReload;

  Future<void> _openMenu(BuildContext context, Offset globalPosition) async {
    // Pull a fresh list every time so a saved-from-another-window
    // connection shows up.
    await registry.reloadProfiles();
    if (!context.mounted) return;
    final profile = registry.profile;
    final profiles = registry.profiles;
    final items = <SearchableMenuItem<_PickerAction>>[
      for (final savedProfile in profiles)
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.switchTo, id: savedProfile.id),
          searchKey: savedProfile.name,
          child: Row(
            children: [
              Icon(
                savedProfile.id == registry.activeId
                    ? Icons.radio_button_on
                    : Icons.radio_button_off,
                size: 14.0,
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: Text(
                  savedProfile.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (savedProfile.readOnly)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4.0,
                    vertical: 1.0,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2.0),
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
            Icon(Icons.add, size: 16.0),
            SizedBox(width: 8.0),
            Text('Add connection…'),
          ],
        ),
      ),
      const SearchableMenuItem<_PickerAction>(
        value: _PickerAction(_ActionKind.refresh),
        searchKey: 'refresh list reload',
        child: Row(
          children: [
            Icon(Icons.refresh, size: 16.0),
            SizedBox(width: 8.0),
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
              Icon(Icons.edit, size: 16.0),
              SizedBox(width: 8.0),
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
                size: 16.0,
              ),
              const SizedBox(width: 8.0),
              Text(registry.isReadOnly ? 'Make read-write' : 'Make read-only'),
            ],
          ),
        ),
        SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.remove, id: profile.id),
          searchKey: 'remove delete current',
          child: const Row(
            children: [
              Icon(Icons.delete_outline, size: 16.0),
              SizedBox(width: 8.0),
              Text('Remove current'),
            ],
          ),
        ),
        const SearchableMenuItem<_PickerAction>(
          value: _PickerAction(_ActionKind.disconnect),
          searchKey: 'disconnect',
          child: Row(
            children: [
              Icon(Icons.power_settings_new, size: 16.0),
              SizedBox(width: 8.0),
              Text('Disconnect'),
            ],
          ),
        ),
      ],
    ];
    final action = await showSearchableMenu<_PickerAction>(
      context: context,
      position: globalPosition,
      items: items,
      hint: 'Find connection or action…',
    );
    if (action == null || !context.mounted) return;
    switch (action.kind) {
      case _ActionKind.switchTo:
        await registry.setActive(action.id, context: context);
      case _ActionKind.add:
        final created = await showAddConnectionDialog(context);
        if (created == null || !context.mounted) return;
        await registry.connectProfile(created, context: context);
        AppState.instance.notifyChange();
      case _ActionKind.edit:
        final target = registry.profileById(action.id!);
        if (target == null) return;
        final edited = await showAddConnectionDialog(context, initial: target);
        if (edited != null) {
          await registry.updateProfile(edited);
          if (!context.mounted) return;
          if (registry.activeId == edited.id) {
            await registry.killConnection(edited.id);
            if (!context.mounted) return;
            await registry.connectActive(context: context);
          }
        }
      case _ActionKind.remove:
        final target = registry.profileById(action.id!);
        if (target == null) return;
        final ok = await confirmDialog(
          context,
          title: 'Remove "${target.name}"?',
          message: 'Saved credentials will be deleted.',
          confirmLabel: 'Remove',
          destructive: true,
        );
        if (ok) {
          await registry.removeProfile(target.id);
          AppState.instance.closeTabsForConnection(target.id);
        }
      case _ActionKind.disconnect:
        await registry.disconnect();
      case _ActionKind.toggleRo:
        final target = registry.profileById(action.id!);
        if (target == null) return;
        await registry.setReadOnly(target.id, readOnly: !registry.isReadOnly);
      case _ActionKind.refresh:
        await registry.reloadProfiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = registry.profile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 8.0),
      child: Row(
        children: [
          Icon(
            profile == null
                ? Icons.power_settings_new
                : (registry.isConnected ? Icons.check_circle : Icons.error_outline),
            size: 16.0,
            color: profile == null
                ? theme.hintColor
                : (registry.isConnected ? Colors.green : Colors.orange),
          ),
          const SizedBox(width: 6.0),
          Expanded(
            child: Builder(
              builder: (buttonContext) => InkWell(
                onTap: () {
                  final box = buttonContext.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final origin = box.localToGlobal(
                    Offset(0.0, box.size.height),
                  );
                  unawaited(_openMenu(buttonContext, origin));
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
                      const Icon(Icons.arrow_drop_down, size: 16.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (registry.isConnecting)
            const SizedBox(
              width: 14.0,
              height: 14.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            )
          else if (profile != null)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, size: 18.0),
              onPressed: () async => onReload(),
            ),
        ],
      ),
    );
  }
}

enum _ActionKind { switchTo, add, edit, remove, disconnect, toggleRo, refresh }

class _PickerAction {
  const _PickerAction(this.kind, {this.id});
  final _ActionKind kind;
  final String? id;
}

import 'package:key_flow/key_flow.dart';

/// The menus the app always has, in menu-bar order. Plugins add to them, or
/// name a new menu, through [CommandContribution.menu].
enum AppMenu {
  file('File'),
  view('View'),
  connection('Connection'),
  ai('AI'),
  help('Help');

  const AppMenu(this.label);

  /// What the menu bar shows, and what [CommandContribution.menu] matches.
  final String label;
}

/// A key_flow id made from a label or another id: `'Metadata'` →
/// `'metadata'`, `'VS Code'` → `'vs_code'`. Ids allow letters, digits, `-`
/// and `_`, and are what the AI agent sees as part of a tool's name.
String commandIdFor(String text) => text.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]+'), '_');

/// Commands a plugin adds to a menu. They also reach the command palette,
/// the shortcut sheet and (unless hidden from it) the AI agent, because all
/// of those read the same key_flow tree.
///
/// [build] runs every time the app's commands are rebuilt (whenever the
/// shell notifies), so it can decide labels, `enabled` and `checked` from
/// live state. A command's `onRun` gets the context of the key_flow root,
/// which sits above the Navigator: use [appContext] for dialogs and
/// snack bars.
class CommandContribution {
  const CommandContribution({required this.menu, required this.build});

  /// Target menu by label: an [AppMenu.label], or a new label, which adds a
  /// top-level menu after the built-in ones.
  final String menu;

  /// The commands to add. They follow the menu's built-in commands after a
  /// divider.
  final List<KeyNode> Function() build;
}

/// Process-wide registry of [CommandContribution]s. Registered once at
/// startup by plugins, read on every rebuild of the app's commands.
class CommandRegistry {
  CommandRegistry._();
  static final instance = CommandRegistry._();

  final List<CommandContribution> _contributions = [];

  void register(CommandContribution contribution) => _contributions.add(contribution);

  /// Every command contributed to [menu], in registration order, a divider
  /// between contributions.
  List<KeyNode> commandsFor(String menu) => [
    for (final contribution in _contributions)
      if (contribution.menu == menu) ...[const KeyDivider(), ...contribution.build()],
  ];

  /// Labels of contributed menus that aren't an [AppMenu], in first-seen
  /// order.
  Iterable<String> get extraMenuLabels {
    final builtIns = {for (final menu in AppMenu.values) menu.label};
    final seen = <String>{};
    for (final contribution in _contributions) {
      if (!builtIns.contains(contribution.menu)) seen.add(contribution.menu);
    }
    return seen;
  }
}

/// The Navigator the app's commands open dialogs on. `DBScopeApp` passes it
/// to `MaterialApp.navigatorKey`.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// A context under the Navigator, for commands that show a dialog or a
/// snack bar. Commands run on a user's click or key press, after the first
/// frame, so the Navigator exists.
BuildContext appContext() {
  final context = appNavigatorKey.currentContext;
  if (context == null) {
    throw StateError('A command ran before the app built its Navigator.');
  }
  return context;
}

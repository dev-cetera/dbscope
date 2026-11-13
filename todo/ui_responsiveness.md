# UI responsiveness audit

What this audit looks for: anything that makes the UI feel slow to answer a click, a drag or a menu. That covers per-frame rebuilds, window-wide notifies on pointer moves, gesture setups that delay taps, and slow default Material animations.

Run it by asking an agent to "audit UI responsiveness" against this file. Last full run: 2026-11-13.

Fixed in the 2026-11-13 run (see CHANGELOG.md): the per-frame `setState` in both canvas tickers, `Resizable`/`VResizable` notifying on every pointer move, the 300 ms tap delay on grid cells, the popup-menu open animation, `InkSparkle` in the VS Code and Portal themes, every card rebuilding during a card drag, every 300 ms `DropdownButton` / `DropdownButtonFormField` (now `InstantDropdown`), the sidebar rebuilding on every `AppState` notify, and Schema pan/zoom and Linked wheel zoom notifying the whole window.

## Open

- **Every `AppState` notify rebuilds the open tab's view.** `_Shell` rebuilds on `shellListenable` (`lib/app.dart`, `_Shell`), and `_Body` builds `_MainArea(active:)`, which rebuilds the active view. This is how views redraw after mutating their tab model and calling `AppState.notifyChange()`, which `docs/architecture.md` ("Tabs & UI shell legacy") calls intentional, so removing it means giving every view its own notifier. The notifies that fired per frame or per pointer move are gone: resize handles, both canvases' viewport anchoring, Schema pan and zoom, and Linked wheel zoom. What's left is one rebuild per user action. Found 2026-11-13. Status: kept.

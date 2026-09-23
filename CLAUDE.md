# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

dbscope is a Flutter desktop database viewer/editor (macOS / Windows / Linux) with a pluggable backend model: Postgres is the original and most fully-featured backend, but the same UI also drives sqflite (local file and on-device pull-edit-push), and more can be added via `ConnectionKindPlugin` (see "Pluggable backends" below). It has a multi-window architecture built on an in-process RPC layer. (The project was previously named "dbscope"; the original `dbscope-plan.md` blueprint lives only in git history.)

## Toolchain & commands

Flutter version is pinned via FVM in `.fvmrc` (3.41.9). Prefix commands with `fvm` to get the right SDK:

```
fvm flutter pub get
fvm flutter run -d macos             # primary dev target
fvm flutter analyze                  # lint via flutter_lints
fvm flutter test                     # whole suite
fvm flutter test test/server_test.dart -p vm   # single file
fvm flutter test test/server_test.dart -p vm --plain-name 'routes req'   # single test by name
```

Tests are per-unit and live under `test/`: `sql_quote`, `envelope`, `cancel_token`, `dml`, `pager`, `server`, `bus_service`, `postgres_executor_decode`, `shell_env`, and the `sqflite_param_translator` suite. They share `test/support/fake_executor.dart` — a `DbExecutor` stub used wherever a test needs to exercise something that would otherwise want a live DB. Each test file opens with a comment block stating the contract it pins down; read that before editing the production code it covers. `test/widget_test.dart` is an intentional placeholder — do not add coverage there.

## Architecture: two isolates, one Server

The single biggest concept that isn't obvious from the plan or from any one file:

**There is exactly one canonical `Server` in the host window's isolate.** Every other window is a subwindow spawned by `desktop_multi_window`, runs in its own isolate with its own Flutter engine, and talks to the host's `Server` via `IsolateTransport` over method channels. The wire format is `Envelope` JSON (`lib/rpc/envelope.dart`) — `req`/`res`/`sub`/`unsub`/`evt`/`end`/`err`. Transports are interchangeable (`LocalTransport` in-process, `IsolateTransport` cross-window).

The boundary:

- `main.dart` branches on `args.first == 'multi_window'`. Host builds `HostBackend` + installs `HostWindowRouter`; subwindows build only an `IsolateTransport`-backed `BackendClient`. Both then run `DBScopeApp` with their `BackendClient` injected via `BackendScope` (`lib/rpc/scope.dart`).
- `Server` (`lib/server/server.dart`) is transport-agnostic. It maps `method` → handler and emits via a `Replier` callback supplied per-`dispatch`. Subscriptions are streams; cancel = `unsub`.
- Services that register handlers: `ProfileService`, `ConnectionService`, `JobService`, `BusService` (all under `lib/server/services/`). `BusService` is the cross-cutting event bus — topics like `profile.changed`, `connection.state:<id>`, `job.progress:<id>`. Subscribe with `topic: 'foo.*'` for prefix matches.

Where state actually lives:

- **Profiles** are owned by `ProfileService` (server). All mutations flow through RPC; the server broadcasts `profile.changed` on the bus and every window's `ConnectionRegistry` rehydrates from that event.
- **`DbExecutor` objects** live in **two** places. `ConnectionService` (server) owns the executor used by server-side code (jobs). `ConnectionRegistry` (per-window, `lib/connection/registry.dart`) owns the executor the UI uses. For Postgres profiles these are two independent TCP sockets to the same database. Keep that in mind before "consolidating" — server-side jobs must not depend on a window being open, and UI features (query cancel via socket close, grid pagination) need a connection they own.
- **Passwords** stay in `flutter_secure_storage`. The server hands them back only to server-side callers (`ConnectionService._open`), never to clients.

When adding a new RPC method, the pattern is: add a `server.onRequest('foo.bar', ...)` in a service, then a thin client wrapper under `lib/rpc/services/` that wraps `client.request('foo.bar', params)`.

## Universal plugin system (DbscopePlugin / DbscopeHost)

Every cross-cutting extension goes through one umbrella interface. `main.dart` has exactly one place where plugins register, and every entry — host built-ins, themes, connection kinds, third-party plugins — shares the same shape:

```dart
DbscopePluginRegistry.instance.register(MyPlugin());
```

- `lib/plugins/dbscope_plugin.dart` defines `DbscopePlugin` (`id` + `label` + `register(host)`) and `DbscopeHost` (a façade over every per-domain registry).
- Every plugin's `register(host)` wires whatever it contributes into the matching sub-registry.

`DbscopeHost` exposes these contribution surfaces:
- **`host.themes`** → `ThemePlugin(id, label, build, overlays)` (`lib/shell/theme_registry.dart`). The active theme's `overlays` are mounted in the root `Stack`, so the Doom mugshot only ships when the Doom theme is registered.
- **`host.connections`** → `ConnectionKindPlugin` (`lib/db/plugin.dart`). Postgres / SQLite / pg-proxy / on-device sqflite.
- **`host.tabs`** → `TabKind` (`lib/tabs/tab_kind.dart`). The eight core tab kinds ship through `BuiltinPlugin`; a plugin can add more.
- **`host.menus`** → `MenuContribution(menu, build)` (`lib/shell/menu_spec.dart`).
- **`host.sidebarActions`** → `SidebarTableAction(...)` (`lib/shell/sidebar_table_actions.dart`).
- **`host.aiBrokers`** → `AiBroker` from `package:ai_broker`. The bundled OpenAI / Anthropic / Gemini brokers register through `BuiltinPlugin`.

### Built-in plugins

| Plugin | Location | What it registers |
|--------|----------|-------------------|
| `BuiltinPlugin` | `lib/plugins/builtin_plugin.dart` | All eight core tab kinds, the default sidebar table-row actions, and the three packaged AI brokers. |
| `PostgresPlugin` | `lib/db/postgres_plugin.dart` | The built-in Postgres connection kind. |
| `SqlitePlugin` | `lib/db/sqlite_plugin.dart` | The built-in local SQLite connection kind. |

Postgres and SQLite are in the host repo (they need no extra package) but follow the exact same `DbscopePlugin` shape, so the registration line in `main.dart` is uniform.

### Platform split

`lib/plugins/platform_plugins.dart` conditionally exports an `_io` or `_web` variant. Both export `List<DbscopePlugin> platformConnectionPlugins()`; `main.dart` iterates that list. The web variant drops Postgres-direct and local SQLite (no dart:io / native libs); only pg-proxy is registered on web.

### Removing a plugin

1. Delete the package folder (e.g. `packages/dbscope_doom_plugin/`).
2. Drop its `path:` dependency from the root `pubspec.yaml`.
3. Drop the `registry.register(MyPlugin())` line in `main.dart`.

The core has zero references to a specific plugin by name. A `grep -rn doom lib/` after the Doom plugin is removed returns nothing functional.

### Theme plugins

Every theme ships as a standalone package; the host has no built-in themes. Currently:

- `packages/dbscope_doom_plugin/` — Doom theme + sprite assets + floating mugshot overlay. The theme's `overlays` list is what makes the mugshot appear; remove the plugin and the mugshot is gone.
- `packages/dbscope_win95_plugin/`
- `packages/dbscope_vscode_dark_plugin/`
- `packages/dbscope_warcraft_plugin/`
- `packages/dbscope_portal_plugin/`

Each theme plugin owns its palette, its `ThemeData` builder, and any asset it ships. Assets shipped from a plugin must use the `packages/<plugin-name>/assets/...` path in `Image.asset(...)` — that's how Flutter finds package-bundled assets at runtime.

The first-registered theme is the fallback when no preference is stored or when the user's saved theme id no longer resolves (e.g. the plugin was removed between sessions). `AppState.setThemeId(id)` is a no-op for unknown ids, so a typo can't silently fall back.

## Pluggable backends (DbExecutor / ConnectionKindPlugin)

dbscope supports more than one kind of database backend. The core never talks to `pg.Connection` directly any more — every call site goes through `DbExecutor` (`lib/db/executor.dart`).

- **DbExecutor** exposes `execute(sql, {positional, named, cancelToken})` returning a `DbResult { columns, rows, affectedRows }`, plus `setReadOnly`, `close({force})`, and `capabilities`. Capability flags (`sessionReadOnly`, `cancelByClose`, `dml`, `transactions`) let UI code disable features cleanly for backends that can't support them — guard at the call site, don't throw `UnsupportedError`.
- **ConnectionKindPlugin** (`lib/db/plugin.dart`) is what produces a `DbExecutor` from a `ConnectionProfile`. Every plugin owns: a `kind` id (the string serialised in `ConnectionProfile.kind`), a label, an `open(profile, {context})` factory, and a `showProfileDialog(...)` builder.
- The built-in `PostgresKindPlugin` (`lib/db/postgres_plugin.dart`) wraps the legacy `pg.Connection` path and is registered from `main.dart`. External plugins register themselves the same way — one `register*()` call from `main.dart`.
- `ConnectionProfile.kind` discriminates which plugin owns a profile. `ConnectionProfile.extra` is an opaque JSON blob the core persists for plugin-owned state (env URL, last-used email, etc.). The core never reads it.
- `CopyTableJob` is a Postgres-only path — it downcasts `DbExecutor` to `PostgresExecutor` (`lib/db/postgres_executor.dart`) and throws `unsupported_backend` for any other kind. Use the same pattern when a feature genuinely requires pg-specific behaviour.
- Removing a plugin = delete its package folder + drop the `path:` dependency in `pubspec.yaml` + drop its `register*()` line in `main.dart`. The core has no plugin-specific imports.

## On-device SQLite plugin (adb / devicectl pull-edit-push)

`packages/dbscope_sqflite_plugin/` lets dbscope read AND edit the SQLite file inside any app on a USB-connected Android / iOS device. There is no in-app agent — file IO goes through `adb run-as` (Android, debuggable APKs only) and `xcrun devicectl` (iOS), wrapped by the bundled `packages/app_data_explorer/` library.

- Profile-kind id on disk stays `'sqflite_remote'` (unchanged from the prior VM-service implementation) so `ConnectionKindRegistry` lookups still match; profile *extras* are different (`deviceKind`, `deviceId`, `appId`, `dbPath`) so old VM-service profiles must be re-saved.
- Add-Connection dialog (`profile_dialog.dart`) is a three-step picker: device → app → on-device .db file. Single-device / single-DB cases auto-select. Apps are filtered to "has reachable data" via `androidAppHasData` / `iosAppHasData`. Files are filtered to `.db`/`.sqlite`/`.sqlite3`/`.db3`, excluding `-wal`/`-shm`/`-journal` sidecars (they're paired automatically at open time).
- Open flow (`DeviceSqliteExecutor.open` in `executor.dart`): pull `<name>.db` plus any `-wal` and `-shm` sidecar into a temp dir, run `PRAGMA wal_checkpoint(TRUNCATE)` to fold WAL into the main file, switch to `journal_mode = DELETE` so subsequent local writes don't recreate WAL sidecars, then wrap the resulting `sqlite3.Database` in a regular `SqliteExecutor`.
- Write path: every `execute` is delegated to the inner `SqliteExecutor`, then if the statement was a write (affectedRows > 0, or a non-SELECT keyword), the main `.db` is pushed back to the device and stale `-wal`/`-shm` on device are deleted. Push uses `adb push /data/local/tmp/ + run-as cp` on Android (because `adb push` can't write directly into `/data/data/<pkg>/`) and `devicectl device copy to` on iOS — see `Backend.push` in `packages/app_data_explorer/lib/app_data_explorer.dart`.
- Concurrency caveat shown in the dialog as a banner: the file is a snapshot. If the device app writes between pull and push, those writes are lost; pushing while the app holds the DB open can corrupt it. Users are told to force-stop the app before editing.
- The executor reports `kind == kSqliteKind` so `SchemaCatalog` reuses the sqlite branch. Capabilities: `sessionReadOnly: true`, `dml: true`, `transactions: false` (each push is an independent network round-trip, can't span a multi-statement TX), `cancelByClose: false`.
- macOS sandbox is **disabled** in `macos/Runner/{DebugProfile,Release}.entitlements` because `Process.run('adb', ...)` / `Process.run('xcrun', ...)` doesn't work inside the sandbox. Do not ship this build to the App Store.
- Android requirements: USB debugging on, target APK built debuggable (release/Play APKs give `run-as: package not debuggable`). iOS: paired device with developer mode.

## Cloud SQL backend (auto-launched Auth Proxy)

`lib/db/cloudsql/` is a built-in connection kind (`kind == 'cloudsql'`, label "Cloud SQL (Postgres)") for GCP Cloud SQL Postgres instances that have no public IP. It is "a Postgres profile reached through a locally-launched Cloud SQL Auth Proxy" — so the regular profile fields carry the Postgres side (host is always `127.0.0.1`, port is the local proxy port), and `ConnectionProfile.extra` carries the proxy side via `CloudSqlConfig` (`instanceConnectionName` = `project:region:instance`, `gcpProject`, `instanceName`, `localPort`, `assignPublicIp`, optional `cloudSqlProxyPath`/`gcloudPath`). Registered from `platform_plugins_io.dart` (IO-only — it shells out to `cloud-sql-proxy` / `gcloud`).

- `CloudSqlKindPlugin.open` (`cloudsql_plugin.dart`): acquire the proxy, then reuse `PostgresKindPlugin.openConnection(...)` (the shared enum-codec discovery, extracted for this) against `127.0.0.1:localPort`, with a retry loop that tolerates the warm-up window of a freshly-assigned public IP but fails fast on auth errors. Wrapped in `CloudSqlExecutor` (extends `PostgresExecutor`, so `is PostgresExecutor` downcasts like `CopyTableJob` still work) which releases the proxy ref on `close()`.
- `CloudSqlProxyManager` (`cloudsql_proxy_manager.dart`): per-isolate, **reference-counted, one proxy per (instance, port)**. If something is already listening on the local port (e.g. `backend/scripts/remote/db_proxy.sh`), it is reused and never killed. Otherwise the manager optionally `gcloud sql instances patch --assign-ip`, spawns `cloud-sql-proxy`, and on the last release kills the proxy + `--no-assign-ip`. Binary resolution searches PATH plus Homebrew / gcloud-SDK dirs because GUI-launched apps get a minimal PATH. Needs the macOS sandbox off (already disabled, same as the sqflite plugin) and `gcloud auth login`.

## Portable connection links (`.dbscopeconn`)

Normally profile JSON omits the password (it lives in the OS keychain, keyed by profile id). A **connection link** (`lib/connection/connection_link.dart`) is the portable alternative: a single self-contained file that carries the whole profile *plus* the password, AES-GCM-256 encrypted under a passphrase (PBKDF2-HMAC-SHA256, 210k iterations; via `package:cryptography`). Loading it decrypts and connects with no keychain dependency, so a link works on any machine. `ConnectionLinkFlow` (`connection_link_flow.dart`) drives import/export from the File / Connection menus (import tries the `DBSCOPE_CONN_PASSPHRASE` env var before prompting — resolved through `ShellEnv`, see "Shell environment" below, so exporting it in `~/.zshenv` is enough). `tool/make_connection_link.dart` generates a link from the CLI (secret via `DB_PASSWORD` / `LINK_PASSPHRASE` env). Round-trip + tamper contract is pinned by `test/connection_link_test.dart`.

## Shell environment (File ▸ Environment…)

**`Platform.environment` is not the environment on desktop.** An app launched from Finder — or from an IDE, or by `flutter run` — inherits launchd's minimal environment, so every `export FOO=bar` in the user's shell profile is invisible to it. A user whose `~/.zshenv` exports `GEMINI_API_KEY` would watch the AI features claim no key is configured.

`ShellEnv` (`lib/util/shell_env.dart`, conditional-export io/web) closes that gap. It reads one shell profile file at startup (`main.dart`, right after `AppState.loadPersisted()`, so the configured path is known) and caches it, so lookups stay synchronous. **`Platform.environment` still wins**; the file only fills gaps. An empty value counts as absent on both sides.

- Default file is `~/.zshenv` — the one zsh file *every* shell sources, login or not, which is why it's where machine-wide exports belong. Null on Windows (no convention to guess at), so the feature is inert there until a path is set. The user overrides the path in File ▸ Environment…; it persists in `UiPrefs.envFilePath`.
- `parseShellEnv` is **not a shell**. It reads `export NAME=value` / `NAME=value` lines plus `source` / `.` includes, and ignores everything else (conditionals, function bodies, command calls) rather than guess. Quotes, `#` comments, and `$NAME` / `${NAME}` expansion follow shell rules; single quotes are literal. Contract pinned by `test/shell_env_test.dart` — read it before touching the parser.
- **Never surface a value in the UI.** The Environment dialog lists variable *names* only; the values are API keys and passphrases, and a screenshot of that dialog has to be safe to paste in a bug report.
- Consumers: `envValue()` in `lib/util/portable_io.dart` (so the `DBSCOPE_CONN_PASSPHRASE` import path gets it for free), `AiKeyResolver` (`lib/ai/ai_key_resolver.dart` — keychain first, then `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY`), and `CloudSqlProxyManager._resolveBinary`. **`PATH` is the one key read via `fileValue` rather than `value`** — the launchd PATH is real, it just lacks whatever the profile prepends, so the two are merged instead of one winning.
- A missing or malformed file is never fatal: `load` records `ShellEnvStatus` + an error string and degrades to "process environment only". The dialog is where that shows up.

## Pluggable tabs (TabKind / TabKindRegistry)

Tab kinds follow the same plugin pattern as connection kinds. Every tab kind owns a `TabKind` constant (`lib/tabs/tab_kind.dart`) that bundles:

- a stable string `id` (persisted in the open-tabs JSON)
- the concrete `TabModel` subclass it owns
- an `IconData` for the tab strip
- a `buildView(tab)` builder
- optional `serialize` / `deserialize` (skip for transient kinds like Job/Json)
- optional `isRunning(tab)` predicate (drives the footer Cancel button)
- optional `footerSummary(tab)` for the bottom-of-window status

Each tab feature folder co-locates its three pieces:

```
lib/table/
  table_tab.dart        # model
  table_tab_view.dart   # UI
  table_tab_kind.dart   # the TabKind constant
```

Same layout for `lib/query/`, `lib/ai/`, `lib/navigator/`, `lib/linked/`, `lib/inspector/json_*`, `lib/shell/jobs/`. Kinds register from `main.dart` (one `r.register(...)` line each), so adding a tab type touches **one new folder + one line in main.dart**. No switch statements anywhere — `_MainArea` (`app.dart`), `restorePersistedTabs` (`app_state.dart`), `_iconFor` (`tab_strip.dart`), and the footer summary all go through `TabKindRegistry.instance.lookupForTab(tab)`.

`AppState` is still a singleton `ChangeNotifier` that owns the tab list, active tab, sidebar layout, and theme. Tab persistence is opt-in: only the host window calls `enableTabPersistence`; sub-windows would otherwise clobber the host's saved list (SharedPreferences is process-wide).

## Pluggable menus + sidebar actions

- **Menu bar** (`lib/shell/menu_bar.dart`): one `_MenuActions` builder returns a `List<MenuSpec>` (`lib/shell/menu_spec.dart`). The native macOS `PlatformMenuBar` and the in-app fallback bar both consume that same data — adding a built-in menu item is a single edit, not a duplicate change in two renderers.
- **Plugin-contributed menu items** go through `MenuContributionRegistry`. Plugins register `MenuContribution(menu: 'File' | 'View' | <new-label>, build: (ctx) => MenuItemSpec(...))` once at startup. The menu builder appends them after the built-ins for that label, or makes a new top-level menu if the label is novel. No edit to `menu_bar.dart` required.
- **Sidebar table-row context menu**: built-in actions are registered from `lib/shell/sidebar_table_actions_default.dart` via `SidebarTableActionRegistry` (`lib/shell/sidebar_table_actions.dart`). Plugins / new features add their own `SidebarTableAction` with no edit to the sidebar widget itself. Each action has an optional `visibleWhen(ctx)` predicate so backend capability gating (e.g. hide soft-delete on read-only backends) doesn't have to live in the sidebar widget.

## Big-feature view files use `part` libraries

A few view files own enough widgets that putting them all in one file makes navigation painful. Those use Dart `part` libraries so the private `_Foo` classes can move into focused files without becoming public:

- `lib/linked/linked_view.dart` — host file declares `library;` and `part 'parts/canvas.dart'` etc. The parts (`canvas.dart`, `edge_painter.dart`, `node_shell.dart`, `node_widgets.dart`, `row_picker_panel.dart`, `table_picker_dialog.dart`) start with `part of '../linked_view.dart';` and share the host's imports.
- `lib/navigator/navigator_view.dart` — host + `parts/{table_list_column,row_list_column,row_detail_column}.dart`.
- `lib/shell/sidebar.dart` — host + `parts/{connection_picker,table_row}.dart`.

Adding a widget to one of these: edit the relevant part file. The host file holds the public entry-point widget + its State.

## Shared State boilerplate (mixins)

Two mixins under `lib/util/` cover the repetitive State plumbing:

- `HoverStateMixin` (`hover_state_mixin.dart`) replaces every `bool _hovered` + `onEnter`/`onExit` triple. Use `isHovered` to read and `setHovered(bool)` to write. Used by `_TabState`, `_CloseDotState`, `_NewTabButtonState`.
- `ListenableStateMixin` (`listenable_state_mixin.dart`) replaces the `singleton.addListener(_onChange)` / `removeListener` / `setState(() {})` triple. Override `listenables` to return the set you want to subscribe to. Used by `_SidebarState`, `_DoomMugshotOverlayState`. Don't use it when the callback needs custom logic (e.g. sidebar's registry listener); use a manual `addListener` there.

## Tabs & UI shell legacy

`AppState.notifyChange()` is called from view widgets that mutate fields directly on the tab model — there's no separate per-tab notifier. This is intentional; don't introduce one.

Themes and reusable widgets live in `packages/widgets/` (Dart package name `widgets`, depended on via `path:`). Two palettes (`win95Palette`, `vsCodeDarkPalette`) implement the shared `AppPalette` `ThemeExtension`; widgets read role-based fields via `AppPalette.of(context)` and shape-adapt via `ChromeKind` (`bevel` vs `flat`). Anything outside the package imports from a single barrel: `import 'package:widgets/widgets.dart';`. The package ships the bundled MS Sans Serif TTF under `lib/assets/fonts/` so it works standalone in any consumer project. Typed-cell colors are driven by the `type*` roles on `AppPalette` (e.g. `typeString`, `typeNumber`, `typeJson`, `typeNull`); the PG-type → role mapping lives in `lib/grid/typed_value_text.dart`.

## The grid and pagination

The grid is a hand-rolled `ListView.builder` widget (`lib/grid/data_grid.dart` and `lib/grid/internal/`) — it replaced `pluto_grid` because pluto couldn't host the shared `ColumnInput` editor, drag-range selection, or TSV copy without major workarounds. Everything that matters about scaling lives in `DataGrid` / `DataGridController`:

- The controller exposes `replaceAll` / `appendRows` / `removeFirstRows` / `removeRowAt` / `prependRow` / `updateCell`. **When a controller is attached, the grid ignores `widget.data` identity changes** — all updates must go through the controller. `QueryTabView` doesn't attach one and keeps reactive behavior; `TableTabView` does.
- `TableTabView` enforces a 50 000-row in-memory window with 5 000-row trim chunks (`_maxBufferedRows`, `_trimChunk`) to make billion-row tables work. Trade-off: scrollback past the window loses rows (use Refresh); changing these numbers shifts the memory-vs-scrollback balance. `removeFirstRows` compensates the scroll offset (`jumpTo(prev - removed * _kRowHeight)`) so the viewport stays put when the top is trimmed.
- Pagination is keyset, not OFFSET. `KeysetPager` (`lib/query/pager.dart`) builds `(sort_col, pk_cols...) > ($lastSort, $lastPk...)` cursors. The optional `baseWhere`/`baseWhereParams` slot is how the Navigator threads inbound-FK and regex filters through the same pager.
- Query tabs cap at 10 000 rows (no pagination). This is deliberate.
- Cancellation: `CancelToken` (`lib/query/cancel_token.dart`) lives on the `TabModel`. The fallback cancel mechanism is closing the underlying connection (`ConnectionRegistry.killConnection`); the user-facing Stop button cancels all currently-running tabs.

Grid view modes (`enum GridViewMode { table, typed }`, in `lib/grid/grid_data.dart`) are passed through to `GridCell`, which uses the mode to flag `CellValueDisplay`'s `colored` / `detectUrl` knobs (`lib/grid/internal/grid_cell.dart`). To add a mode that just tweaks cell rendering, add an enum value and branch in `GridCell`; for a mode that swaps the whole grid (card / gallery view), branch one level up in `TableTabView`. Tab models already persist `viewMode`.

## Navigator (Miller-column explorer)

`NavigatorTab` is a path of `NavStep`s rendered as horizontally-stacking columns à la Finder. `RowListStep` lazy-paginates via `KeysetPager` fetching **PK columns only** (cheap on huge tables); `RowDetailStep` shows one row with FK chips and inbound-relation rows, delegating field rendering to the shared `PropertyInspector` (`lib/inspector/property_inspector.dart`, also used by the table view's right-side panel). `pushFrom(i, step)` is canonical Miller behavior (truncate-and-append). The sidebar is the implicit column 0 — a `TableListStep` class exists but is never constructed in production. The regex filter and inbound-FK filter are threaded into `KeysetPager` via its `baseWhere` / `baseWhereParams` slot, so they compose with the keyset cursor rather than bypassing it.

## Linked view (FK graph canvas)

`LinkedTab` (`lib/linked/`) is the third row-explorer alongside `TableTab` and `NavigatorTab`. The canvas is a `Stack` of free-floating, drag-by-header nodes connected by bezier edges; each node is either a `LinkedRowNode` (single row → `PropertyInspector`) or a `LinkedListNode` (paginated `KeysetPager` rows the user clicks to promote into row nodes). Outbound FK clicks in the inspector spawn row nodes; inbound clicks spawn list nodes filtered by the inbound FK (same `InboundFilter` the navigator uses). The cached `foreignKeys` list is loaded once per tab. Nodes are a fixed `_kNodeWidth × _kNodeHeight` so the edge painter can anchor connectors to rim midpoints without measuring widget sizes — a clean shape but it constrains body content. Background-pan lives as a `Positioned.fill` at the bottom of the stack so node hit-tests preempt it (otherwise horizontal drags inside an inspector field would pan the canvas instead of selecting text). Seed entry points: sidebar context menu → "Open as Linked" (sets `seedSchema`/`seedTable`, bootstraps a list node on first build), or empty `LinkedTab` + "Add table" header button.

Row cards are rendered via the shared `SchemaCard` widget (see "Schema viewer"), with `SchemaFieldSpec.valueDisplay` populated from the loaded `row` map — so a Linked row card shows live data values instead of column type labels once the row loads. Edge styling (gradient stroke + two animated chevrons per edge, 3.5s cycle) is identical to the Schema viewer's `_EdgePainter` so the two views feel like one product.

## Schema viewer (`View → Schema`)

The diagram primitives live in **`packages/schema_viewer/`** as a backend-agnostic Flutter package. The host app supplies `SchemaNodeData` + `SchemaEdgeData` and the package handles layout, rendering, pan/zoom/drag, click-to-isolate, and edge animation. Exports: `SchemaCanvas`, `SchemaCard`, `SchemaEdgePainter`, `layoutSchemaNodes`, `cascadeSeparate`, `colorForTable` / `buildTableColorMap` / `kRelationshipPalette` (the relationship-gutter palette), `colorForType` / `classifyTypeName`, and the dimension constants. The package has zero dbscope-specific imports — drop it into any Flutter app that has tables and FKs.

`SchemaTab` (`lib/schema/`) is the host-side glue: it loads the catalog (schemas → tables → columns + the global FK list) via `SchemaCatalog`, maps the result onto the package's data types, runs the layout, and renders `SchemaCanvas`. Layout modes: LR (default) and TB. The Sugiyama-style ranked layout is in `packages/schema_viewer/lib/src/schema_layout.dart` — not full dagre, but close enough for typical schemas (60+ tables) and zero external deps.

Card states: idle, `isSelected` (2-px primary outline, deeper shadow), `isHighlighted` (neighbour in the same FK component as the selection), dimmed (anything else, 35% opacity, when something is selected). Selecting any card isolates its 1-hop FK neighbourhood; clicking the background clears the selection. Header affordances: `onActivate` (drill-in action — the Schema tab wires it to open a `TableTab`; the Linked view wires it to open the row's table in a fresh tab), `onToggleCompact` (PK/FK-only filter — both hosts wire this). Edges are gradient bezier strokes with two chevrons animating along the path (3.5s cycle); a single `Ticker` per canvas drives every chevron, not per-edge animations.

Entry point: `View → Schema` (Cmd-D) in `menu_bar.dart`; that method focuses the existing `SchemaTab` for the active connection if one is open, otherwise creates a fresh one. The tab kind is registered through `BuiltinPlugin` alongside the other built-ins.

The palette previously living at `lib/shell/relationship_gutter.dart` (`colorForTable`, `colorIndexForTable`, `buildTableColorMap`, `kRelationshipPalette`) was moved into `package:schema_viewer/schema_viewer.dart`; `relationship_gutter.dart` re-exports them so existing import sites (sidebar, etc.) keep working unchanged.

## SQL safety invariants

These are non-negotiable; the plan covers them and the codebase enforces them:

- **Identifier vs value quoting.** Schema/table/column names go through `quoteIdent` / `quoteQualified` (`lib/util/sql_quote.dart`). Values are positional params (`$1`, `$2`). Never concatenate user values into SQL.
- **Optimistic concurrency on UPDATE.** All cell edits issue `... AND <col> IS NOT DISTINCT FROM $oldValue`. 0 rows affected = conflict toast + refresh that row. See `lib/db/dml.dart`.
- **Read-only mode** is enforced by `SET default_transaction_read_only = ON` on the connection itself, not by parsing SQL. Toggled per-profile; `ConnectionService` and `ConnectionRegistry` both apply it on open and on `setReadOnly`.

## Postgres version floor

dbscope targets **Postgres 14–17** — i.e. every currently-supported PG major version. The catalog SQL in `lib/catalog/schema_catalog.dart` references three columns/features whose introduction sets a hard floor below that range:

- `pg_attribute.attgenerated` (PG 12) — used to detect `GENERATED ... STORED` columns in `listColumns`.
- `pg_attribute.attidentity` (PG 10) — used to detect `GENERATED ... AS IDENTITY` columns.
- `unnest(...) WITH ORDINALITY` (PG 9.4) and `array_position` (PG 9.5) — used by `listForeignKeys` / `primaryKey`.

The driver (`postgres ^3.5.11`) does not constrain the floor further in practice. If you add catalog SQL, prefer features available in PG 14 so the floor stays at "currently-supported only" — don't reach into PG 16/17-only catalog views without a server-version branch, and don't drop below PG 14 expectations without updating this section.

## Other notes

- **Table-open latency:** `TableLoader.loadTable` (`lib/query/runner.dart`) fires `listColumns`, `primaryKey`, `indexedColumns` together via `Future.wait` (the driver pipelines them); only the first-page `fetchNext` blocks on the catalog round. `TableTabView` also keeps a single-slot prefetch (`_nextPagePrefetch` / `_kickPrefetch`) so the next page is buffered before the user scrolls to it. The pager is not safe for concurrent `fetchNext` — the slot enforces one in-flight at a time, and `_load` / errors clear it.
- **Relationship gutter:** `lib/shell/relationship_gutter.dart` routes each FK edge in its own vertical lane keyed by sorted index (so an edge's lane and color are stable across reloads). Adjust `laneSpacing` / `laneMin` / `cornerRadius` together — the lane count is derived from the available width up to `anchorX - cornerRadius`.

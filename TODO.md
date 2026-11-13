# TODO

> [!IMPORTANT]
> **Bugs don't go here. They go in `BUGS.md`.**
>
> If what you're writing down has a real failure (wrong output, a crash, lost data, a check that can never fire), it's a bug. The test is the failure, not the size. "It works, but…" goes here. "It's broken, but…" does not.

Work for coding agents that isn't a defect: polish, deferred work, improvements, open questions, "this works but should become X". Newest first. Work only a human can do goes in `MANUAL_TODO.md`.

Don't read this file whole. Search it first:

```sh
rg -n --max-count 5 '<file or symbol>' TODO.md
```

## Entry format

```text
### **[P2]** <one-line statement of what should be done>

- **Where.** `path/to/file:123`, or the area or doc it affects.
- **Why.** What's wrong with it today and what doing it gets us.
- **Effort.** `<15min`, `<1h`, `<4h`, `<1d`, `>1d`, or `investigation`.
- **Blocker.** `none`, or what it waits on, for example "needs a decision on X".
- **Noticed.** YYYY-MM-DD, while <what you were doing>.
```

A job a cheap model can close without making any judgement calls gets `[SIMPLE]` next to its priority (`**[P3] [SIMPLE]**`, `Effort: <15min`). It has to meet all three conditions: it touches one file or one block, it doesn't change behaviour or any name other code depends on, and an existing check (a test, the linter, a script) shows whether it worked. To work through them in one batch:

```sh
rg -n '\[SIMPLE\]' TODO.md
```

## Priority tiers

- **P0** blocks a release, or is a live risk right now.
- **P1** is high value and doable soon.
- **P2** is worth doing but safe to put off.
- **P3** is nice to have.

## Open

<!-- New entries go here, newest first. -->

### **[P2]** Support PGlite databases

- **Where.** A new connection kind beside `lib/db/cloudsql/` (a plugin that launches `@electric-sql/pglite-socket` and connects through `PostgresKindPlugin.openConnection`, the way Cloud SQL launches its proxy), or a README how-to if a plain Postgres profile turns out to be enough.
- **Why.** PGlite (Postgres in WASM) has no support today. Its socket server speaks the Postgres wire protocol, but it allows one client unless `--max-connections` is raised, and dbscope opens several connections per database: one for server-side jobs, one per window, one for each copy job (`ConnectionService.openDedicated`), and a short-lived one for every Stop (CancelRequest). Newer pglite-socket versions run all connections through one query queue, so Stop may not interrupt a running statement, and pooled multi-connection use was still getting protocol fixes in April 2026. Check open-table paging, cell edits, query tabs, Stop, copy jobs and the catalog SQL against the PG version PGlite ships (`docs/architecture.md` targets 14–17).
- **Effort.** `investigation`, then `<1d`.
- **Blocker.** none.
- **Noticed.** 2026-11-14, when asked whether dbscope supports PGlite.

### **[P1]** Drive dbscope with apprentice end to end and fix what it can't name or reach

- **Where.** `macos/Runner/MainFlutterWindow.swift`, the labelled controls across `lib/` and `packages/`, `test/agent_accessibility_test.dart`. See "Accessibility for screen readers and agents" in `docs/architecture.md`.
- **Why.** The accessibility tree is now switched on in every window and controls carry names, but none of it has been read on a real Mac yet (held back on request). Run `apprentice session --app dbscope`, then `read`: connect, open a table, edit a cell, run a query, open the code editor window, use `menu "File > …"`. Anything listed as an unnamed `textbox`, missing, or only reachable by coordinates needs a label. Also confirm the subwindow repost of the accessibility notice turns the tree on there.
- **Effort.** `<4h`.
- **Blocker.** none (the owner asked to wait before testing with apprentice).
- **Noticed.** 2026-11-14, while making dbscope readable to apprentice.

### **[P2]** Name the pg-proxy and on-device SQLite dialog fields, and move their dropdowns to `InstantDropdown`

- **Where.** `packages/dbscope_pg_proxy_plugin/lib/src/profile_dialog.dart` (all fields, the SSL mode dropdown), `packages/dbscope_sqflite_plugin/lib/src/profile_dialog.dart` (Name field, the device/app/file dropdowns).
- **Why.** Neither package depends on `widgets`, so their text fields can't use `FieldName` and read as unnamed boxes to macOS accessibility clients (apprentice, VoiceOver). They also still use `DropdownButtonFormField`, whose menu takes 300 ms to open, against the `InstantDropdown` rule in `docs/architecture.md`. Add a `widgets` path dependency to both pubspecs, then wrap the fields and swap the dropdowns.
- **Effort.** `<1h`.
- **Blocker.** none.
- **Noticed.** 2026-11-14, while making dbscope readable to apprentice.

### **[P3]** Name the grid's inline cell editors for accessibility clients

- **Where.** `lib/grid/inputs/parts/raw_text_input.dart` and the other `ColumnInput` editors under `lib/grid/inputs/parts/`.
- **Why.** The editor doesn't know its column's name, so on macOS an agent editing a cell sees an unnamed text box. Pass the column name down through `ColumnInput` and wrap the field in `FieldName`.
- **Effort.** `<1h`.
- **Blocker.** none.
- **Noticed.** 2026-11-14, while making dbscope readable to apprentice.

### **[P3]** Name the navigator's filter-column dropdown for accessibility clients

- **Where.** `lib/navigator/parts/row_list_column.dart` (the `InstantDropdown` that picks which column the regex filter applies to).
- **Why.** It has no `labelText`, so macOS accessibility clients read it only by its current choice (`button "[AI Infer]"`). An agent can't tell what it chooses. Give it a name without changing how it looks, for example an optional semantic label on `InstantDropdown`.
- **Effort.** `<1h`.
- **Blocker.** none.
- **Noticed.** 2026-11-14, while making dbscope readable to apprentice.

### **[P2]** Give the query tab, grid and inspector their own key_flow commands

- **Where.** `lib/query/query_tab_view.dart` (Run, Stop, Ask AI, Save), `lib/query/sql_editor.dart` (its own `Shortcuts` for ⌘↩), `lib/inspector/property_inspector.dart` (Esc / ⌘↩), `packages/data_grid` (keys stay in the package; dbscope would wrap the grid in a `KeyFlowScope` that calls its actions).
- **Why.** Only the app-wide commands are in the key_flow tree so far. Per-area commands would show up in the ⌘K palette, the `?` sheet and the agent's tools while that area has focus, and replace the scattered `Shortcuts` widgets.
- **Effort.** `<1d`
- **Blocker.** none
- **Noticed.** 2026-11-13, while moving the menus onto key_flow.

### **[P2]** Let users change shortcut keys

- **Where.** `lib/shell/app_key_flow.dart` (already saves key_flow's `onKeyOverridesChanged` to `UiPrefs.keyOverrides` and passes them back), a new Help ▸ Keyboard shortcuts… editor, or key_flow's shortcut sheet.
- **Why.** The saving and restoring of custom keys is wired, but nothing in the UI calls `KeyFlowController.setKeys`, so users can't remap anything yet. The 2026-11-13 changelog line about key_flow says "shortcuts can be remapped and are remembered", which isn't true until this lands.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-13, while moving the menus onto key_flow.

### **[P3]** Let Stop abort the model-list lookup too

- **Where.** `AiTarget._firstModel` (`lib/ai/ai_target.dart`), `listModels` and `checkKey` in `package:ai_broker`.
- **Why.** With no model saved ("auto"), each AI call first asks the provider for its model list. ai_broker 0.9.0 can abort chat requests but not `listModels`, so a Stop during that lookup stops the wait (`untilCancelled`) while the request runs on. It costs no tokens, but a slow local endpoint keeps a socket busy.
- **Effort.** `<4h` (an `abortTrigger` on `listModels`/`checkKey` in ai_broker, then pass it through)
- **Blocker.** none
- **Noticed.** 2026-11-13, from the ai_broker abort work.

### **[P3]** Stream AI answers and show their token cost

- **Where.** `SqlAssistant.askSql`, `AgentSession.send` (`lib/agent/agent_session.dart`), `lib/shell/footer.dart`.
- **Why.** Both wait for the whole reply. ai_broker's `streamWithMeta` gives the text as it arrives plus input/output token counts, which the footer could show per tab.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-13, while moving AI calls to ai_broker 0.9.0.

### **[P3]** Add widget tests for the Stop button's wiring and the next-page failure toast

- **Where.** `lib/shell/footer.dart`, `_loadMore` in `lib/table/table_tab_view.dart`, `_load` in `lib/navigator/parts/row_list_column.dart`.
- **Why.** The logic behind them is tested (`AppState.cancelAll`, `LatestRequest`), but nothing proves the widgets call it, so a wiring mistake would pass the suite.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-07, while listing what the bug fixes left untested.

### **[P3]** Share the enum-codec discovery between the desktop executor and the proxy

- **Where.** `PostgresExecutor.loadEnumCodecs` in `lib/db/postgres_executor.dart`, `_loadEnumCodecs` and `_EnumCodec` in `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart`.
- **Why.** Two copies of the same code. `packages/dbscope_pg_core` now exists, so one can live there, as the value decoder does.
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-07, while moving the value decoder.

### **[P2]** Compute table histograms server-side instead of sampling the first 10 000 rows

- **Where.** `lib/meta/chart_sql.dart` (`kHistogramSampleRows`), `lib/meta/charts/chart_data.dart`, `lib/meta/charts/chart_view.dart`.
- **Why.** A table histogram now says it is a sample, but it still bins the first 10 000 rows in heap order, so the shape can differ from the whole table. Bucket counts computed in SQL would be exact. Named-query and inline-SQL histograms are also never labelled as samples.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-07, while fixing the histogram-sample bug.

### **[P3]** Hide, or reword the tooltip of, a `roles:` action on a connection with no access control

- **Where.** `actionUnavailableReason` in `lib/meta/ui/meta_menu.dart`.
- **Why.** Such an action is now unavailable (correct), but the tooltip still reads "Only for roles: …", which does not say why it is closed there.
- **Effort.** `<15min`
- **Blocker.** none
- **Noticed.** 2026-11-07, while fixing the `roles:` bug.

### **[P3]** Place new Linked view cards using their real size, not a guessed one

- **Where.** `lib/linked/linked_view.dart:464` (`_placeNextTo`).
- **Why.** It looks for a free slot as if the new card were `source.width` wide and four rows tall. The canvas now pushes neighbours away once the card's real size is known, so nothing overlaps, but a tall or wide card can make its neighbours jump a moment after it appears. Placing it with its real size (or the compact-column count, which is known from the FKs) would avoid the jump.
- **Effort.** `<1h`.
- **Blocker.** none.
- **Noticed.** 2026-11-03, while fixing overlapping schema diagram cards.
### **[P2]** Find out whether the release build still needs `disable-library-validation`

- **Where.** `macos/Runner/Release.entitlements` (`com.apple.security.cs.disable-library-validation`)
- **Why.** With hardened runtime it lets the app load libraries signed by anyone, which undoes much of what signing buys. The release workflow signs every bundled dylib with our own identity, so it may no longer be needed; removing it needs a signed build launched on a Mac (sqlite3 and the plugin frameworks are the libraries to watch).
- **Effort.** `<1h`
- **Blocker.** needs a signed build and a Mac (see "Sign and notarize the macOS release" in `MANUAL_TODO.md`).
- **Noticed.** 2026-11-03, while auditing for production readiness.

### **[P2]** Undo the Cloud SQL public IP after a crash

- **Where.** `lib/db/cloudsql/cloudsql_proxy_manager.dart`
- **Why.** When the manager assigned a public IP, it removes it on the last release. If dbscope crashes or is force-quit first, the instance keeps the public IP (and the orphaned `cloud-sql-proxy` keeps running) until someone notices. Recording "we assigned it" on disk and offering to undo it on the next launch would close that.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while auditing for production readiness.

### **[P2]** Make Tab move to the next cell, and let multi-line cells take a newline, in grid inline editing

- **Where.** `packages/data_grid/lib/src/internal/grid_cell.dart` (`_editor` shortcut bindings)
- **Why.** Tab commits but leaves the selection where it was, so you can't tab across a row as in a spreadsheet. Enter always commits, so a `multiLine` text column can't get a line break inline (the row dialog works).
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while fixing inline cell editing.

### **[P2]** Fix the paths in `docs/architecture.md` that point at nothing

- **Where.** `docs/architecture.md`: `packages/dbscope_doom_plugin`, `packages/dbscope_warcraft_plugin` ("Theme plugins"; `pubspec.yaml` comments also say they are "kept under packages/"), `lib/shell/jobs`, `lib/grid/internal/` and `lib/grid/internal/grid_cell.dart` (grid probably moved to `packages/data_grid`). Found by `bash scripts/agent/info_doc_drift.sh paths`.
- **Why.** Contributors follow the architecture doc first; paths that don't exist send them hunting. Run `/find-stale-references`.
- **Effort.** `<1h`
- **Blocker.** the Doom/Warcraft part needs a decision: restore the packages from history, or drop the references.
- **Noticed.** 2026-10-30, while setting up the agent kits.

### **[P3] [SIMPLE]** Give the pre-commit hook a fast check

- **Where.** `.githooks/pre-commit` (`CHECK=""`).
- **Why.** Hooks are opt-in (`scripts/setup_dev_env.sh`); a `fvm dart format --output=none --set-exit-if-changed lib test` check would catch unformatted commits for anyone who turns them on.
- **Effort.** `<15min`
- **Blocker.** none
- **Noticed.** 2026-10-30, while installing agent-project-template.


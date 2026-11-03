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

### **[P3]** Show type names for enums, domains and extension types in query result headers

- **Where.** `lib/db/postgres_executor.dart` (`pgTypeNameForOid`, the built-in oid table).
- **Why.** Query headers now show built-in type names instead of `Type(oid:2950)`, but a column whose type is an enum, a domain or an extension type (`citext`, PostGIS) has a per-database oid that isn't in the table, so its header shows no type and the typed-cell colour falls back to plain. A per-executor cache filled by one `SELECT oid, typname FROM pg_type WHERE oid = ANY($1)` for unknown oids would cover them.
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while fixing the `Type(oid:N)` header bug.

### **[P3]** Offer a reconnect when a connection link is re-imported for a profile that is already connected

- **Where.** `lib/connection/registry.dart` (`_connect` now returns early when the profile is connected), `lib/connection/connection_link_flow.dart`.
- **Why.** Connecting an already-open profile used to dial a second socket and leak the first. It now keeps the live connection, so credentials refreshed by re-importing a link only apply after the user disconnects and connects again. The import flow could say so, or offer "Reconnect now".
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while fixing the duplicate-connection bug.

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


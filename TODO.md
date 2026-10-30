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


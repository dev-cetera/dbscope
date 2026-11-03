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

### **[P1]** Let the pg proxy restrict which database hosts a client may open

- **Where.** `packages/dbscope_pg_proxy/bin/dbscope_pg_proxy.dart` (`_onOpen`)
- **Why.** The client names the host and port in its `open` message, so a proxy reachable from a network is a pivot to any Postgres that network can reach, guessing credentials as it goes. An `--allow-db-host host[:port]` list (default: any, as today) would let an exposed proxy be pinned to its one database. The proxy also bounds neither message size nor result rows; a `--max-rows` cap would stop one `SELECT *` from exhausting its memory.
- **Effort.** `<4h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while hardening the proxy for production.

### **[P2]** Keep the pg proxy shared secret in the keychain, not the profile JSON

- **Where.** `packages/dbscope_pg_proxy_plugin/lib/src/profile_dialog.dart`, `executor.dart` (`extra['sharedSecret']`)
- **Why.** It is a credential, but it lives in `ConnectionProfile.extra`, which is saved in plain text in the project file and travels unencrypted in anything that copies profile JSON. Passwords already go through `SecureStore`; the secret should too.
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while auditing for production readiness.

### **[P2]** Add Help ▸ Show crash log

- **Where.** `lib/util/error_reporting.dart` (`crashLogPath`), `lib/shell/menu_bar.dart`
- **Why.** Uncaught errors now go to `~/Library/Logs/dbscope/dbscope.log`, but nothing in the app says so except the release-mode broken-widget placeholder. A menu item that reveals the file in Finder would make it easy to attach to a bug report, and the issue template could ask for it.
- **Effort.** `<1h`
- **Blocker.** none
- **Noticed.** 2026-11-03, while adding the crash log.

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


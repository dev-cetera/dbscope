# AGENTS.md

How coding agents work in this repo. `CLAUDE.md` and `GEMINI.md` only import this file, so make changes here.

## About the project

dbscope is an open-source (MIT), openly vibe-coded desktop database viewer and editor for Postgres, Cloud SQL, local SQLite and SQLite inside apps on USB-connected phones, with an AI assistant that writes SQL. It's built with Flutter (pinned via FVM in `.fvmrc`; always prefix `flutter`/`dart` with `fvm`). macOS is the shipped target, the web build reaches Postgres only through `packages/dbscope_pg_proxy`, and outside contributors work on it, so leave the code clearer than you found it. User-facing overview: `README.md`. Contributor guide: `CONTRIBUTING.md`.

**Read `docs/architecture.md` before any non-trivial change.** It explains the parts no single file shows: the one `Server` in the host window that every other window talks to over RPC, the plugin system, where state and passwords live, and the SQL safety invariants. Claude Code loads it automatically via `CLAUDE.md`; other agents must open it.

This file is a map, not a copy of the docs. When something here points at a doc, go and read it instead of guessing. If something is unclear, stop and ask.

## Write down what you notice, always

This is part of every task, not a separate job, and nobody will ask you to do it. While you work, anything you notice and don't fix goes into the right file straight away. At the end of every task, anything still broken or unfinished goes in too. Don't go hunting for problems, but don't let one you saw disappear. Saying it in chat doesn't count: chat is gone when the session ends.

| File | What goes in it | Who closes it |
|---|---|---|
| `BUGS.md` | Anything with a real failure: wrong output, a crash, lost data, a check that can never fire | an agent or a developer |
| `TODO.md` | Work with no failure: polish, deferred work, improvements, open questions | an agent |
| `MANUAL_TODO.md` | Work an agent in a terminal can't do: logins, payments, keys, legal advice, a real device | a human |
| `CHANGELOG.md` | One line per change that matters, and one per bug fix | written by the script, never read |
| `todo/<topic>.md` | Findings from an audit or sweep someone asked for | see `todo/AGENTS.md` |

The test for a bug is the failure, not the size. A one-line typo that corrupts a value is a bug. A whole module that works but should be rewritten is a TODO.

Before you say a task is done, check:

1. Did I notice a bug I didn't fix? It's in `BUGS.md`.
2. Did I leave anything unfinished, put off or worth improving? It's in `TODO.md`.
3. Does something need a person (a login, a key, a decision)? It's in `MANUAL_TODO.md`.
4. Did I fix a bug or change behaviour? There's a changelog line from `scripts/add_changelog_line.sh`, and the fixed entry is gone from `BUGS.md` or `TODO.md`.

Name the entries you added or closed in your final message. If there was nothing to record, say so in one line. The `record-keeping` skill (`.agents/skills/record-keeping/SKILL.md`) has the details: which file, checking for duplicates, the entry format, closing an entry.

## Folder guides

Some folders have their own `AGENTS.md`, with a `CLAUDE.md` beside it that imports it. Read the guide before you change anything in that folder. Claude Code loads it by itself when you touch the folder. Other agents may not, so open it yourself.

| Folder | Read its guide before you |
|---|---|
| `lib/` | write or change code (also applies to the packages under `packages/`) |
| `test/` | add or change tests |
| `docs/` | write or change docs |
| `scripts/` | add or change a script |
| `todo/` | run an audit or sweep, or work through its findings |

A guide holds the rules for its own folder and nothing else. When you add a guide, add a row here.

## Rules for every change

- **Ask before anything you can't undo.** Deploys, deleting data, force pushes, publishing, sending email, spending money. Show what you are about to do and wait for a yes.
- **Never invent.** If you don't know a path, a command, an API or the reason something is the way it is, look it up or ask. A confident guess costs more than a question.
- **Stay on the task.** Don't widen the diff with fixes nobody asked for. Write them down instead (see "Write down what you notice").
- **Simple means the end result, not the effort.** If the clean result needs a rename across 200 files, do the rename. Don't leave half-renamed names, compatibility shims or "proper fix later" notes behind.

## After making changes

- Run the checks: `fvm flutter analyze` and `fvm flutter test` (one file first: `fvm flutter test test/<name>_test.dart`). CI runs the same two on every PR. Each test file opens with a comment stating the contract it pins down; read it before changing the code it covers. `test/widget_test.dart` is a deliberate placeholder.
- Changes under `site/` (the landing page) or `.github/workflows/` have no tests: check the page in a browser at desktop and phone width, and run `actionlint` on workflows.
- If behaviour, UI, the API, the schema or deployment changed, add one changelog line:

  ```sh
  bash scripts/add_changelog_line.sh "<what changed, for whom>"
  ```

  Skip it for refactors, formatting and doc-only edits. Every bug fix gets a line.
- If you made a decision a future developer needs to know about, write it in the doc that already covers that part of the system. Don't start a new doc for it. If no doc fits, ask.

## Working efficiently

Everything you read stays in context and is paid for again on every later turn.

- **Never read these files whole:** `BUGS.md`, `TODO.md`, `MANUAL_TODO.md`. Search them for the file or symbol you care about, then read that part.
- **`CHANGELOG.md` is write-only.** Never open, search or tail it. Add to it only with `scripts/add_changelog_line.sh`. Claude Code's settings block reading it.
- **Always give a search a path,** for example `rg -n 'name' src/`. Read line ranges, not whole files. Look at `git diff --stat` before the full diff.
- **Run one test file before the whole suite.**
- **Report briefly.** End with the files you changed, the checks you ran and anything left open.

<!-- Installers such as robertsolves/agent-commands add their own section below this line. -->

<!-- BEGIN robertsolves/agent-commands -->
## Agent commands from robertsolves/agent-commands

Each workflow lives in `.agents/commands/<name>.md`. They came from `install.sh`, and re-running it overwrites them, so put anything about this project in `.agents/project-facts.md` instead. The commands read it. As you work, file anything you notice and don't fix in the records the **Records** bullet there names (usually `BUGS.md` and `TODO.md`), without being asked.

Run one as `/name` in Claude Code, OpenCode, Kilo, Gemini CLI, Antigravity, Cursor, Copilot and Windsurf, as `$name` in Codex, or as `/skill:name` in Freebuff. In any other agent, ask it to open `.agents/commands/<name>.md` and follow it.

Commands: `/audit-devex` `/audit-product` `/audit-slop` `/check-production-readiness` `/find-bad-comments` `/find-bandaids` `/find-compliance-issues` `/find-confusing-things` `/find-dead-code` `/find-exploits` `/find-readability-improvements` `/find-seo-aeo-improvements` `/find-stale-references` `/find-unfinished` `/improve-markdowns` `/interview-code` `/interview-docs` `/interview-risky-spot` `/refine-findings` `/resume-session` `/setup-project-facts` `/unify-patterns` `/update-docs`
<!-- END robertsolves/agent-commands -->

<!-- BEGIN robertsolves/dart-agent-kit -->
## Agent commands from robertsolves/dart-agent-kit

Each workflow lives in `.agents/commands/<name>.md`. They came from `install.sh`, and re-running it overwrites them, so put anything about this project in `.agents/project-facts.md` instead. The commands read it. As you work, file anything you notice and don't fix in the records the **Records** bullet there names (usually `BUGS.md` and `TODO.md`), without being asked.

Run one as `/name` in Claude Code, OpenCode, Kilo, Gemini CLI, Antigravity, Cursor, Copilot and Windsurf, as `$name` in Codex, or as `/skill:name` in Freebuff. In any other agent, ask it to open `.agents/commands/<name>.md` and follow it.

Commands: `/dart-audit-code` `/dart-clean-packages` `/dart-improve-code`
<!-- END robertsolves/dart-agent-kit -->

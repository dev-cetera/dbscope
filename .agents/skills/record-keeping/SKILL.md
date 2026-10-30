---
name: record-keeping
description: "Decides where a problem or leftover piece of work gets written down: BUGS.md for anything with a real failure, TODO.md for agent work with none, MANUAL_TODO.md for what only a person can do, CHANGELOG.md for every fix. Covers how to add, update or close an entry without duplicating it. Use when you notice a bug outside your task, when a task ends with something still broken or left undone, when you fix something BUGS.md or TODO.md lists, or when you tidy either file. Not for an audit someone asked for: its findings go in todo/<topic>.md."
---

# BUGS.md, TODO.md, MANUAL_TODO.md and CHANGELOG.md

Write down what you notice along the way. Don't go hunting for it. A chat summary is not a record: anything left broken or undone when your task ends gets written down without being asked.

## Step 1: Fix it or file it

- **Part of your task and fixable now:** fix it. Nothing gets filed.
- **Outside your task, or not fixable now** (it needs a decision, a credential, or would blow up the diff): file it (Step 2).
- **A small job noticed in passing:** don't fix it inline. File it in `TODO.md` as `**[P3] [SIMPLE]**` with `Effort: <15min`, but only if all three hold: it touches one file or one block, it changes no behaviour and no name other code depends on, and an existing check (a test, the linter, a script) shows whether it worked. At most three per session.

## Step 2: Pick the file

Ask these in order. The first yes wins.

1. **Does it have a real failure?** Wrong output, a crash, lost data, a check that can never fire. It goes in `BUGS.md`, even if it's one line. Style, naming or "could be cleaner" is never a bug.
2. **Can an agent in a terminal not close it?** A dashboard login, a paid account, a key, a card, artwork, legal advice, a real device. It goes in `MANUAL_TODO.md`, under the group its routing table names.
3. **Otherwise** (polish, deferred work, an improvement, an open question, or a decision a person makes before an agent builds it): it goes in `TODO.md`. A decision gets `Blocker: needs a decision on X`.

An item with a human step and agent work behind it is filed in both `MANUAL_TODO.md` and `TODO.md`, and each entry names the other. Never file one thing in both `BUGS.md` and `TODO.md`.

## Step 3: Check it isn't already there

Never open these files whole. Search for the file or symbol first:

```sh
rg -n --max-count 5 '<file name or symbol>' BUGS.md TODO.md MANUAL_TODO.md
```

If it's already listed, update that entry (new evidence, a corrected line number, higher confidence) instead of adding another.

## Step 4: Write the entry

Read the file's own entry format:

```sh
rg -n -A 12 '^## Entry format' <the file>
```

Fill every field. Each entry cites evidence as `path:line` and gives today's date as YYYY-MM-DD. A `BUGS.md` entry states its confidence (`suspected`, `likely` or `confirmed`). A `TODO.md` entry starts with a priority tag (`**[P0]**` to `**[P3]**`). Add new entries at the top of the file's `## Open` section with your file-edit tool. In `MANUAL_TODO.md`, add it under the right group and priority.

## Step 5: Close what you resolve

| What happened | What to do |
|---|---|
| You fixed a bug | Delete its `BUGS.md` entry and add a changelog line in the same change. Every bug fix gets a line, listed or not. |
| You did a TODO | Delete its `TODO.md` entry. Add a changelog line if behaviour, UI, the API, the schema or deployment changed. |
| You decided not to fix a bug | Move it to `BUGS.md`'s **Accepted limitations** with the reason and what would change the decision. |
| It was a false alarm | Delete the entry. |
| A TODO turned out to be a defect | Move it to `BUGS.md`. Don't copy it. |

## CHANGELOG.md is write-only

Never read `CHANGELOG.md`. Not whole, not a line range, not a search, not a check for duplicates. It only grows, and every read is paid for again on every later turn. Add to it only with the script, which puts the line under today's date:

```sh
bash scripts/add_changelog_line.sh "<one line: what changed, for whom>"
```

Never edit an older line. A duplicate line costs nothing. A read costs thousands of tokens.

## Done means

- `rg -n --max-count 5 '<file or symbol>' BUGS.md TODO.md MANUAL_TODO.md` shows exactly one entry for what you filed, and none for what you closed.
- Every bug you fixed has its changelog line, added by the script (exit 0).
- Nothing left broken or undone at the end of your task exists only in your chat summary.
- Your final message names the entries you added or closed.

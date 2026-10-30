---
name: dart-improve-code
description: >-
  Conservatively edit Dart/Flutter code to be simpler and harder to misuse, in one behaviour-preserving pass. Hardens first (names and keys, `late`, nullability, boundaries), then simplifies (cryptic names, premature abstraction, dead code). Run after `/dart-audit-code`, or on changed files before a PR, or when asked to harden or simplify named Dart files. Not for a report with no edits — use /dart-audit-code; not for a readability ranking of structure (mode flags, logic in UI) — use /find-readability-improvements.
---

# dart-improve-code

Read `../../commands/dart-improve-code.md` (from the project root: `.agents/commands/dart-improve-code.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.

---
name: dart-audit-code
description: >-
  Audit Dart/Flutter code for anti-patterns, null/late usage, magic map keys, names that should be enums, complexity, and pattern drift. Read-only: no edits. Run when asked to review, audit or check Dart code against the rulebook, or before a PR. Not for applying fixes — use /dart-improve-code; not for lint and format — use /dart-clean-packages.
---

# dart-audit-code

Read `../../commands/dart-audit-code.md` (from the project root: `.agents/commands/dart-audit-code.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.

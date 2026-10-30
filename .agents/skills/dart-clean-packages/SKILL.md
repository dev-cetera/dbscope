---
name: dart-clean-packages
description: >-
  Clean and lint every Dart package in the project — dart fix, dart format, dart analyze, then targeted greps for violations of the project's Dart style rulebook. Never touches generated files. Run when asked for Dart hygiene, "clean the packages", "lint everything", or before a PR that spans several packages. Not for a read-only review — use /dart-audit-code; not for a judgement-based simplify pass — use /dart-improve-code.
---

# dart-clean-packages

Read `../../commands/dart-clean-packages.md` (from the project root: `.agents/commands/dart-clean-packages.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.

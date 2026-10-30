---
name: dart-discipline
description: Apply Effective Dart guidelines (and the project's `dart-discipline.md`, if installed) whenever Claude touches Dart or Flutter code. Triggers on `.dart` files, `pubspec.yaml`, widgets, pods / blocs / riverpod / signals state, Flutter tests, build runners, or any conversation that mentions Dart, Flutter, pub.dev, or `df_*` packages.
---

# Dart discipline

Apply Dart and Flutter discipline whenever you touch Dart code. The skill ships with the canonical Effective Dart guides as siblings of this file at `./effective-dart/<section>.md`, resolved relative to this `SKILL.md` wherever the harness has installed the skill. Load only the section the current task needs: never all of them at once: so context stays small.

## Precedence (top wins)

1. **Project rules**: the project's `dart-discipline.md` rule file — `.agents/rules/dart-discipline.md` or `.claude/rules/dart-discipline.md`, whichever exists (the installer links the second to the first). These are opinionated overrides and almost always say more than the Dart community baseline. **In Claude Code this file auto-loads path-scoped the moment you touch a `.dart` file (the rule's own `paths:` glob), so it's usually already in context — don't re-read it and pay for it twice.** Read it yourself only when it isn't already present: a first-touch turn before the injection lands, a single-shot `claude -p` run, or a harness (Gemini / OpenCode) that doesn't consume `rules/*.md` at all. Skip if the file is absent.
2. **Effective Dart**: `effective-dart/<section>.md` (this skill). The community baseline. Load the relevant section per the decision table below.
3. **Dart defaults**: what you already know about idiomatic Dart and Flutter.

When project rules and Effective Dart disagree, the project rule wins. When the project rule is silent, Effective Dart applies. When both are silent and the task is non-obvious, ask the user rather than guessing.

## Strict analyzer settings

This skill ships the analyzer settings that back these rules: `analysis_options/dart.yaml` (every Dart lint listed on or off, each "off" with a reason) and `analysis_options/flutter.yaml` (the same plus Flutter's generated folders). To point a package at them:

```sh
bash .agents/skills/dart-discipline/scripts/use_strict_analysis.sh <package-dir>   # or --all for every package
```

It adds one `include:` line to the package's `analysis_options.yaml` and never touches an existing include unless given `--replace`. Switch a single rule off in the package's own file, under `linter: rules:`, with a comment saying why. Never edit the shipped copies: the installer replaces them.

## Which doc to load

- **Naming or formatting** (class, file, variable, parameter, top-level constant; import order; trailing commas) → `effective-dart/style.md`.
- **Comments and doc comments** (`///`, regular comments, library docstrings) → `effective-dart/documentation.md`.
- **Code bodies** (strings, collections, control flow, function expressions, variables, members, constructors, error handling, async/await, isolates) → `effective-dart/usage.md`.
- **Public API design** (library structure, class hierarchy, constructor shape, parameter list, return type, generics, equality / `hashCode`) → `effective-dart/design.md`.

For a focused audit / harden / simplify pass over existing code, hand off to `/dart-audit-code` or `/dart-improve-code` (if installed in this project). They load `dart-discipline.md` themselves and don't need this skill's docs to do their job.

If a task spans categories (e.g. adding a new public class: naming + design + usage + docs), load the docs in order as each concern comes up. Don't preload all four.

When citing a guideline back to the user, name the verb and the section heading verbatim: for example *"Effective Dart usage: DO use `??` to convert `null` to a boolean value."* The verbs carry weight and should not be paraphrased. The five verbs (DO / DON'T / PREFER / AVOID / CONSIDER) and the shared Dart-terminology glossary are formally defined in `effective-dart/overview.md`; consult it if a user asks what the verb actually commits them to (e.g. "is this a hard rule or a suggestion?").

## When this skill activates

Activate when any of these are true; don't activate otherwise:

- The file being read, edited, or written has a `.dart` extension.
- The project root (or a parent directory) contains a `pubspec.yaml`.
- The user mentions Flutter, Dart, a widget, pub, pub.dev, `df_*` packages, riverpod, bloc, drift, isar, hive, freezed, build_runner, or asks about a Dart-specific pattern.

If none of these hold, stay silent. The skill should never trigger on, say, a Kotlin/Swift native module just because a Flutter project sits next to it.

## Behaviour

- This skill applies rules to anything you produce. **It does not edit files on its own.** If the user wants a sweep over existing code, point them at `/dart-audit-code` (read-only) or `/dart-improve-code` (behaviour-preserving edits).
- It does not load every reference doc eagerly: only the section the current task needs.
- It does not duplicate rules. If a rule needs to change, change the source: `dart-discipline.md` for project overrides, or note that the upstream Effective Dart guide is what to update (not this skill's local copy: those copies are a snapshot for offline reference).
- If a rule conflicts with what the user explicitly asked for, surface the conflict in one sentence and let the user choose. Don't silently override either side.
- If the user asks "why?" about a guideline, the corresponding `effective-dart/<section>.md` includes the rationale paragraph from the canonical source. Quote that, don't invent.

## What's in `effective-dart/`

Each file is a curated extract of the canonical Dart team guide, with the verbs preserved verbatim and short examples kept inline.

- `overview.md`: what DO / DON'T / PREFER / AVOID / CONSIDER actually commit you to, plus the shared glossary (library member, class member, member, variable, type).
- `style.md`: naming, ordering, formatting (~19 guidelines).
- `documentation.md`: comments and doc comments (~25 guidelines).
- `usage.md`: day-to-day code patterns (~43 guidelines).
- `design.md`: API design (~61 guidelines).

The header of each file links to the canonical source on dart.dev. Treat the local copy as a cached reference; if you suspect it's outdated, the URL in the header is authoritative.

## Hard rules for this skill

- Never preload all four `effective-dart/` section docs at once: load only the section the current task needs.
- Never edit existing Dart files as a "sweep" under this skill. Hand the user off to `/dart-audit-code` (read-only) or `/dart-improve-code` for that.
- Never paraphrase the Effective Dart verbs (DO / DON'T / PREFER / AVOID / CONSIDER). Quote them verbatim with the section heading.
- Never edit the local `effective-dart/<section>.md` copies as if they were the source of truth: they are a cached snapshot of dart.dev.
- Never activate on non-Dart files just because a `pubspec.yaml` exists nearby (e.g. Kotlin or Swift sources in a Flutter project's native folders).

## Done means

- You loaded only the `effective-dart/` section the task needed, after the project rule file.
- Every Effective Dart guideline you cited is quoted with its verb (DO / DON'T / PREFER / AVOID / CONSIDER) and section heading.
- `dart analyze --fatal-infos` (or `fvm dart analyze` when the repo has `.fvmrc`) passes in each package whose Dart you edited.

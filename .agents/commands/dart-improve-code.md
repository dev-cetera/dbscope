---
description: Conservatively edit Dart/Flutter code to be simpler and harder to misuse, in one behaviour-preserving pass. Hardens first (names and keys, `late`, nullability, boundaries), then simplifies (cryptic names, premature abstraction, dead code). Run after `/dart-audit-code`, or on changed files before a PR, or when asked to harden or simplify named Dart files. Not for a report with no edits — use /dart-audit-code; not for a readability ranking of structure (mode flags, logic in UI) — use /find-readability-improvements.
argument-hint: "[paths or 'all'] (default: changed files in git)"
---

# /dart-improve-code
Edit Dart / Flutter code so it is more defensible and simpler to read, per the `dart-discipline` rule, without convoluting it. Hardening (Rules 2-5) runs before simplifying (Rules 6-9) because earlier fixes shrink the work for later ones.

**Behaviour-preserving.** If a fix would change observable behaviour, do not apply it: list it under "Skipped" in the report.

**Writes:** only the in-scope `.dart` files. Write the report in your reply, not to a file.

## Step 1: Load the rule and the project facts

```sh
rg -n '^- \*\*(Checks and tests|Readability and comments|Dart packages)\*\*' .agents/project-facts.md | head -n 5
rg -n '^## Rule [1-9]' .agents/rules/dart-discipline.md | head -n 9
```

Read the three facts lines, then read `.agents/rules/dart-discipline.md` Rules 1-9 (skip the rest). From the facts, write down these placeholders and use them below:

- `<analyze>`, `<format>`, `<test>`: the project's analyze, format and test commands (the "After making changes" list the Checks fact points to). If it names an SDK wrapper, use it.
- `<generated>`: the generated-file patterns to leave alone (Dart packages fact).
- `<field-names>`: where generated field-name constants live (grep target for Step 4a).
- `<layout-rules>`: where a new widget class goes (Readability fact).

Done when: you have written down all five placeholders. If a fact is missing, stop and ask: "The project facts give no `<name>` — what is it?"

## Step 2: Resolve the scope

Arguments: `$ARGUMENTS`

| `$ARGUMENTS` | Files |
|---|---|
| empty | changed `.dart` files plus untracked ones (commands below) |
| `all` | every `.dart` file under `lib/` and `test/` of the current package |
| anything else | the listed files or folders |

```sh
git diff --name-only "$(git merge-base HEAD origin/HEAD)" -- '*.dart' | head -n 200
git ls-files --others --exclude-standard -- '*.dart' | head -n 100
```

If `origin/HEAD` is missing, use `origin/main`, then `origin/develop`. Drop every file matching `<generated>`.

Done when: you printed the resolved file list. If it is empty, stop.

## Step 3: Pre-flight check

```sh
git status --short | head -n 60
<analyze> 2>&1 | tail -n 15
```

Note the dirty files outside the scope and the baseline issue count.

Done when: the baseline count is written down. If the baseline has analyzer errors, stop and ask: "The build already has errors — fix them first, or stop?" (we cannot tell which errors would be ours).

## Step 4: Harden, one file at a time

Per file, do 4a to 4e in order, one concern at a time. Never blend two kinds of edit in one change. Stop on an analyzer regression: fix or revert before the next file. Done when: every in-scope file went through 4a-4e and the analyzer count is still at or below baseline.

### 4a. Names and keys (Rule 4)

Find: string literals used as map keys, JSON field names, route, prefs, storage, collection, event, flag or query-parameter names; `abstract final class` members that repeat their own value (`static const ITEMS = 'items';`); enums whose argument repeats the member (`ITEMS('items')`); hand-rolled enum lookups (`values.firstWhere((e) => e.name == s)`, `byName`, `asNameMap()[s]`, a `switch` on the raw string, `try { byName } catch`).

```sh
rg -nF "'<key>'" --max-count 5 <package dir> | head -n 30
rg -nF "\"<key>\"" --max-count 5 <package dir> | head -n 30
rg -n --max-count 3 '<key>' <field-names> | head -n 10
```

Run the first two for each key; the third checks for an existing generated constant before you invent one.

| The string is | Action |
|---|---|
| a constant already generated in `<field-names>` | use it |
| a name from a closed set (collection, prefs slot, event, flag, job, asset) | add a member (UPPER_SNAKE, `.name` is the string) to the existing enum; if none exists, list a new enum under "Skipped" |
| a key of one record (JSON field, map key, query parameter) used in two or more places | promote to a constant in the folder's existing keys file (or `_keys.dart`): `abstract final class FooKeys { static const id = 'id'; }`, identifier equal to the value |
| a key used in one place | leave it |
| a hand-rolled enum lookup | the project's one lookup helper (for example df_type's `X.values.valueOf(s)`), with the miss handled as before (`?? (throw …)` where the old code threw, `?? X.A` where it defaulted); note that `valueOf` ignores case and trims, if the old lookup was exact |
| a string-constant class turning into an enum, or a member's spelling changing | do not apply: it changes what is stored or sent (a data migration); list it under "Skipped" with the stored places it touches |

Then fix imports. If the folder has a barrel file, regenerate it in Step 6.

Done when: no in-scope literal fits the first three rows, and each skipped one is in your notes.

### 4b. `late` elimination (Rule 2)

For each `late` field, take the first row that fits:

| Situation | Action |
|---|---|
| can be `final` with an initialiser at the declaration | make it `final` |
| can be `final` set in a constructor initializer list | make it `final`, move the init |
| set in a `State`'s `initState` | leave `late final`; list it under "Skipped" (never introduce it silently) |
| "computed once on first access" | do not change; suggest a getter caching in a private nullable, under "Skipped" |
| anything else | make it nullable (`Foo? _foo;`), update read sites |

If the nullable fix adds more than 2 `!` per former `late`, revert it and list it under "Skipped".

Done when: no in-scope `late` is left except the listed ones.

### 4c. Nullability tightening (Rule 3)

For each `T?` field, parameter or return type:

| Situation | Action |
|---|---|
| field set in every constructor | drop the `?`, make the parameter `required` |
| parameter defaulting to `null` that the body treats as "no value" | non-nullable with a sensible default (`[]`, `''`, `0`), only if `rg -n '<name>: null' <package dir> \| head -n 20` shows no caller passing `null` |
| return type where every caller does `?? x` or `!` | do not change; list it for the human (design question) |
| removing `?` would need a magic sentinel | never; leave it |
| the change needs edits outside the in-scope files | skip; list it |

Done when: each `T?` was tightened or has a row's reason noted.

### 4d. Boundary validation (Rule 5)

This step is judgement and file edits; it has no command.

- At HTTP / file / IPC / DB / user-input boundaries, a `Map<String, dynamic>` whose downstream code assumes keys needs a decode step (model class or typed accessor). If it exists, leave it. If missing, do not write one: list it under "Skipped" (a design choice).
- Remove redundant internal checks: a null check on a non-nullable value, a try/catch that re-throws the same exception, `if (x == null) return;` for a non-nullable `x`.
- Do not add new defensive checks deeper in the code. Never add a silent fallback (a `?? default` or `catch` that hides a bug); follow the project's stricter error-handling bar if its agent guide sets one.

Done when: every boundary map is either typed already or listed.

### 4e. `dynamic` and unsafe casts (Rules 7, 9)

This step is judgement and file edits; it has no command.

- `dynamic` local / field / parameter: narrow to the real type (skip `Map<String, dynamic>` at a JSON boundary).
- `as` casts in business logic: use a typed alternative (pattern match, sealed class, `is` with promotion). Leave a cast the surrounding code already validated.

Done when: no in-scope `dynamic` or business-logic `as` is left unless listed.

## Step 5: Simplify, one file at a time

This step is judgement and file edits; it has no command. Read `.agents/skills/dart-improve-code/references/simplify_list.md`, then per file: apply what fits, re-read to confirm the edit applied cleanly, move on. If an edit left the file's intent less clear, revert it.

Done when: each in-scope file was re-read after its last edit.

## Step 6: Verify

```sh
<analyze> 2>&1 | tail -n 15
<format> <touched files>
<test> 2>&1 | tail -n 30
```

- The new issue count must be at or below the Step 3 baseline. If higher, the new issues are yours: fix or revert.
- Format touched files only; never bulk-reformat.
- Run tests unless the user said to skip. If the suite is large, narrow to test files matching the edited basenames, one folder at a time (a large Flutter suite can run out of memory whole).
- If a barrel file needs regenerating, use the generator the project's agent guide names; never hand-edit it.

Done when: the analyzer count is at or below baseline and the test tail shows no failures. If a command fails twice with the same error, stop and report its output.

## Step 7: Report

Reply with this shape, filled in, and write it nowhere else:

```
# Dart Improve

**Files edited:** <count>
**Analyzer:** baseline <N> → after <M> (delta <±X>)
**Tests:** <pass/fail/skipped>

## Hardened
- `path:line`: <names and keys / late / nullability / boundary / dynamic: what changed>

## Simplified
- `path`: <what changed, with site counts>

## Skipped (flagged for human)
- `path:line`: <why, and what the human decides>

## Not touched
- `path`: already clean.
```

Done when: the reply has all five parts.

## Hard rules

- **No behaviour changes.** Renaming a public API, changing a signature, altering control flow that affects output, switching algorithms: forbidden. A `null` becoming a non-null parameter is a contract change: apply only when grep shows no caller passes null.
- **No new abstractions or dependencies.** Extracting a Widget class is allowed (Rule 7 mandates it for `_buildFoo`). A base class, mixin, extension or helper file is not. Use only what `pubspec.yaml` has.
- **No `!` proliferation.** If an edit adds more `!` than it removes, revert it.
- **Never touch files matching `<generated>`** (for example `*.g.dart`, `*.freezed.dart`, `*.gen.dart`, `*.mocks.dart`, `build/`, `.dart_tool/`, `ios/Pods/`). Barrel files are regenerated, never hand-edited.
- **One file at a time.** Read, edit, re-read, move on.

## Done means

```sh
<analyze> 2>&1 | tail -n 5
git diff --stat | tail -n 20
```

The analyzer count is at or below the baseline and `git diff --stat` lists only in-scope `.dart` files.

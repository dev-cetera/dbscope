---
description: "Audit Dart/Flutter code for anti-patterns, null/late usage, magic map keys, names that should be enums, complexity, and pattern drift. Read-only: no edits. Run when asked to review, audit or check Dart code against the rulebook, or before a PR. Not for applying fixes — use /dart-improve-code; not for lint and format — use /dart-clean-packages."
argument-hint: "[paths or 'all'] (default: changed files in git)"
allowed-tools: Read, Grep, Glob, Bash
---

# /dart-audit-code
Read-only audit of Dart / Flutter code against the `dart-discipline` rule.

**This command edits nothing and creates no file.** Not even formatting. The report goes in your reply only.

## Step 1: Load the rule and the project facts

Run:

```sh
rg -n '^- \*\*(Readability and comments|Dart packages|Patterns|Checks and tests)' .agents/project-facts.md | head -n 5
```

These lines give `<readability-bar>` (the project's "readable at a glance" rule and its screen-folder shape), `<pattern-catalogue>` (the project's named patterns) and `<generated-file-glob>`. Then Read `.agents/rules/dart-discipline.md` (skip if already in context). It is the authority: if this command conflicts with it, the rule wins. Never audit from memory.

Done when: you have read the rule file and the four lines above. If the rule file is missing, stop and ask: "Where is the dart-discipline rule file?"

## Step 2: Resolve the scope

Arguments: `$ARGUMENTS`

| `$ARGUMENTS` | Scope |
|---|---|
| empty | changed `.dart` files (command below) |
| the word `all` | every `.dart` file under `lib/` and `test/` of the current project |
| anything else | exactly the listed files, and nothing else; a directory expands to its `.dart` files. Do not run the command below or search for more files. |

For the empty case:

```sh
B=$(git merge-base HEAD origin/HEAD 2>/dev/null || git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/develop)
{ git diff --name-only "$B"...HEAD -- '*.dart'; git diff --name-only -- '*.dart'; } | sort -u | head -n 200
```

Skip `<generated-file-glob>` files. Print the file count and the first five names.
Done when: the count is printed. If it is 0, stop and say "No Dart files in scope."

## Step 3: Read the files and collect violations

No command: this step is judgement. Read the in-scope files (in parallel where independent) and check each against these sections of the rule file:

- §1 behaviour-preservation hazards (flag risky-looking refactors in a mixed diff)
- §2 `late`
- §3 unnecessary nullability (`T?` fields always set, parameters defaulting to null without reason)
- §4 magic-string map keys, JSON field names, route names, prefs keys; string-constant classes that repeat their own values, or an enum constructor that repeats its member (§4a: should be an enum and `.name`); hand-rolled enum lookups (`values.firstWhere(… .name == …)`, `byName`, `asNameMap()[…]`, a string `switch`)
- §5 over-defensive code (redundant null checks, blanket try/catch, asserts mirroring the type system)
- §6 oversized functions, deep nesting, premature abstraction
- §7 cryptic identifiers, `_buildFoo` helpers, raw `dynamic`, `as` casts, magic numbers, integer doubles
- §8 pattern drift against `<pattern-catalogue>` (list as "potential drift", never as certain)
- §9 anti-pattern catalogue: match each item
- file layout per `<readability-bar>`: flag a screen file that mixes layout with loading, writes, rules or handler bodies, and a screen whose layout is shattered into tiny widgets

For each violation note: file path, line number, rule section, one-line description, one-line fix. Read only the files in scope; do not explore further than needed to ground a finding. A finding needs a specific line: "this file feels complex" is not one; "function `foo` at line 80 nests 6 levels" is.
Done when: every in-scope file has been read.

## Step 4: Write the report

Write one markdown report in your reply, in this shape. Never write it to a file: no `Write`, no `Edit`, no `>` redirect. Reaching for one means you misread this command: stop and re-read it.

```
# Dart Review

**Scope:** <N files>
**Files:** <bullet list of every file reviewed>

## Critical: behaviour or safety
- `path/to/file.dart:42`: §2 `late` field `_foo`: make `final` with initialiser or nullable.

## Important: readability and patterns
- `path/to/file.dart:108`: §4 magic key `'userId'` repeated in 3 files: promote to `UserKeys.userId`.
- `path/to/store_names.dart:12`: §4a `static const ITEMS = 'items';` repeats its value: make `StoreName` an enum and store `.name` (a stored spelling changes: plan the migration).

## Minor: style and consistency
- `path/to/file.dart:17`: §7 `ctx` → `context`.

## Observations (no action requested)
- File X uses one state idiom; file Y in the same screen uses another. Human chooses direction (§8).

## Summary
- Critical: <count>
- Important: <count>
- Minor: <count>
```

| Section | What goes in it |
|---|---|
| Critical | crash or data-corruption risk: `late`, broken nullability, unsafe casts, swallowed errors that should propagate |
| Important | readability, duplication, missing single source of truth, over-defensive code |
| Minor | naming, doubles, formatting-adjacent issues |

Cap each section at 50 entries: write the top 50 and add "and N more". Never truncate the file list. Do not grade: no score, no "quality: B+".
Done when: the reply ends with the three summary counts.

## Step 5: Recommend the next command

End the reply with exactly one line:

| Report | Last line |
|---|---|
| any finding | Run `/dart-improve-code` to apply the null/late/key-dedup and readability/consistency fixes. |
| none | Nothing to do. |

Done when: that line is the last line of the reply.

## Done means

- No file was edited or created (`git status --short` shows nothing new from you).
- The reply holds the report, ending with the summary counts and the one-line recommendation.

---
description: Clean and lint every Dart package in the project — dart fix, dart format, dart analyze, then targeted greps for violations of the project's Dart style rulebook. Never touches generated files. Run when asked for Dart hygiene, "clean the packages", "lint everything", or before a PR that spans several packages. Not for a read-only review — use /dart-audit-code; not for a judgement-based simplify pass — use /dart-improve-code.
---

# /dart-clean-packages
This is a lint and format pass only. It edits Dart source in the packages in scope and nothing else. Write the summary in your reply, not to a file.

## Step 1: Load the project's Dart facts

```sh
rg -n '^- \*\*(Dart packages|Checks and tests)\*\*' .agents/project-facts.md | head -n 5
```

Read the two bullets. They give you:
- `<rulebook>`: the Dart style rulebook file, with its caveats about `dart fix`;
- `<generated-globs>`: the generated-file globs, and the out-of-scope packages;
- `<analyze-cmds>`: the analyze commands (Flutter packages may also need `flutter analyze`).

If the repo has `.fvmrc`, prefix every `dart` / `flutter` command with `fvm`.
Done when: you have written down `<rulebook>`, `<generated-globs>`, the out-of-scope packages and `<analyze-cmds>`. If a bullet is missing, stop and ask: "Which file is the Dart style rulebook, and which packages are out of scope?"
If `<generated-globs>` is empty, treat as generated: `*.g.dart`, `*.freezed.dart`, `*.gr.dart`, `*.mocks.dart`, `*.pb*.dart`, any file whose header says it is generated, and `.dart_tool/` and `build/`.

## Step 2: List the packages

```sh
find . -name pubspec.yaml -not -path '*/.dart_tool/*' -not -path '*/build/*' -not -path '*/.symlinks/*' -not -path '*/ephemeral/*' -not -path '*/node_modules/*' | head -n 40
find . -mindepth 2 -name .git -not -path '*/node_modules/*' -not -path '*/build/*' | head -n 20
```

Drop every package inside a folder the second command lists (nested repos) and every out-of-scope package from Step 1. A package whose `pubspec.yaml` has `sdk: flutter` is a Flutter package.
Done when: you have a numbered list of in-scope package folders. If it is empty, stop and ask: "No Dart packages are in scope. Which folder should I clean?"

## Step 3: Apply auto-fixes (writes files)

In each package, from its own directory:

```sh
dart fix --apply
dart format <the dirs among lib test integration_test tool bin that exist in this package>
```

Then read `git diff` of that package for what `dart fix` changed. Revert by hand (file-edit tool, never `git checkout` or `git restore`, other sessions edit this tree) any import it added only to resolve a doc-comment reference, and anything `<rulebook>` says `dart fix` must not do.
Done when: both commands exited 0 in every package and the diff holds no import or change the rulebook forbids. If a command fails twice with the same error, stop and report the output.

## Step 4: Analyze

Run `<analyze-cmds>` in each package, for example:

```sh
dart analyze --fatal-infos
```

Done when: each package prints `No issues found!`. With more than 20 issues in total, fix the first 15 and list the rest in your reply.

## Step 5: Enforce the style rulebook (greps, then edits)

Read `<rulebook>` once. For each rule a grep can catch, run one capped grep per package, keyed to the rule as the rulebook states it:

```sh
rg -n --max-count 5 '<pattern>' <package>/lib <package>/test -g '*.dart' -g '!<generated-glob>' | head -n 40
```

| Situation | Action |
|---|---|
| The rulebook states the rule and a grep can catch it | grep, open only the matching files, fix against the rule as written |
| Zero hits | skip, do not open files |
| The rule needs judgement (logic in `build()`, business logic in UI, API use) | skip, this pass does not review it |
| The rulebook does not state the rule | do not grep for it |

Shapes that often fit, if the rulebook has the rule: `\b(print|debugPrint)\(` for a logging rule, `\bvar ` for final-over-var, `^\s*enum ` (read each body) for enum-member casing, `\b(height|width|fontSize|radius|elevation|opacity|size)\s*:\s*[0-9]+\b` for explicit-`.0` doubles, `\b_build[A-Z][A-Za-z0-9]*\s*\(` for no build helpers, `package:<banned_lib>` for a banned dependency, a single-file `import` from a folder that has a barrel.
This step is edits plus greps. Never edit a generated file. Never change logic, rename public APIs or restructure code.
Done when: every greppable rule has been run in every package and each hit is fixed or listed in your reply.

## Step 6: Check file names

```sh
find <package>/lib <package>/test -name '*.dart' -not -name '*.g.dart' -not -name '*.freezed.dart' | rg -v '/[a-z0-9_]+\.dart$' | head -n 40
```

Add a `-not -name` for each other `<generated-globs>` pattern. Each line printed is a name that is not `lower_snake_case.dart`. Do not rename any file. List them in your reply.
Done when: the command was run for every package, and its output (or `none`) is in your reply.

## Step 7: Re-verify and report

Re-run Step 4's analyze commands. Reply in this shape and write it nowhere else:

```text
packages: 6 cleaned, 1 skipped (nested repo)
fixed: 14 (dart fix 9, rulebook greps 5)
analyze: No issues found! in every package
left for you: 2 analyze issues in <package>, 1 file name <path>
```

Done when: the reply has all four lines and the analyze line matches what the commands printed.

## Done means

- `dart fix --apply` and `dart format` ran in every in-scope package and exited 0.
- `<analyze-cmds>` print `No issues found!` in every in-scope package, or the remaining issues are listed.
- No generated file, `pubspec.yaml` or `analysis_options.yaml` was edited (unless it was a clear bug, named in the reply).

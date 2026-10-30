---
name: dart-search
description: "Find where a Dart class, mixin, enum, extension or typedef is declared and which files use it, or search Dart code with capped output, without flooding the context with a raw grep. Use whenever you need to locate a Dart symbol or pattern in a project with more than a handful of files."
---

# dart-search

Two read-only scripts beside this file. Both skip generated code (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`), `build/` and `.dart_tool/`, cap their output, and need `rg` (ripgrep).

Run them from anywhere in the project. The paths below are from the project root.

```sh
bash .agents/skills/dart-search/scripts/info_find.sh <Symbol>        # declaration file:line, then up to 15 files that use it
bash .agents/skills/dart-search/scripts/info_find.sh <Symbol> -t     # include tests
bash .agents/skills/dart-search/scripts/info_grep.sh '<regex>' [path] # matching files (20 max), then 3 matches from each of the first 8
bash .agents/skills/dart-search/scripts/info_grep.sh '<regex>' [path] -a  # include generated code
```

Exit codes: 0 found, 1 nothing found, 2 bad arguments.

To skip more files (big data tables, translations), set `DART_SEARCH_EXCLUDE` to a comma list of globs, for example `DART_SEARCH_EXCLUDE='**/l10n/**,**/emoji_table.dart'`.

Use `info_find.sh` before `info_grep.sh` when you know the symbol's name. When `info_grep.sh` says 20 files, narrow the pattern or the path instead of reading all of them.

## Done means

- You found what you were looking for, or one of the scripts exited 1 and you said so.
- You did not run an uncapped `grep -r` or `rg` over the whole project.

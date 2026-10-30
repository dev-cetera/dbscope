# scripts/agent/

Small read-only scripts that answer questions about the repo with short output, so agents don't paste huge command dumps into their context.

Every script here follows these rules:

- **Read-only.** It never changes the repo, a database or an environment.
- **Short output.** Every list is capped. A script that can print 500 lines is a bug.
- **Plain text.** No colours, no pagers, no prompts.
- **Exit codes mean something.** 0 is healthy or clean. Anything else needs attention.
- **Grow on effort, not on repetition.** Sessions can't see each other, so nobody can tell a question "came up twice". The trigger is simpler: if answering a question about the repo took a pipeline or more than a couple of commands, save it here before the task ends. A script nobody reuses costs nothing. A pipeline rebuilt by hand costs every session.
- **List it twice.** Add a line below and to the list in `scripts/AGENTS.md`, so a new session finds it without reading this file.

## Scripts

- `info_diff.sh [base-ref]`: branch, changed files per top folder, diffstat and untracked files. The default base is `HEAD`, which shows uncommitted work. Pass `origin/main` to see the whole branch.
- `info_find.sh <Symbol> [-t]`: where a class, function, type or constant is declared, in most languages, then the files that mention it (15 max). Skips tests unless `-t`. Exit 1 when nothing is declared under that name.
- `info_grep.sh <pattern> [path] [-a]`: matching files first (20 max), then 3 matches from each of the first 8, 4000 characters max. Skips build output, vendored and generated code and `CHANGELOG.md`. `-a` includes them. Exit 1 when nothing matches.
- `info_scripts.sh [keyword]`: every script in the repo with its one-line description, grouped by folder.
- `info_doc_drift.sh [links|paths]`: markdown links and backticked paths in the docs that point at nothing. The mechanical half of keeping docs true.

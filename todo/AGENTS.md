# Audit records

Each file here is the running record of one kind of audit, for example `todo/exploits.md`, `todo/dead_code.md` or `todo/stale_references.md`. These are findings someone asked for: a security sweep, a dead-code hunt. Bugs and TODOs noticed in passing go in `BUGS.md` and `TODO.md` at the root instead.

- **One file per audit topic,** named after the topic in snake_case. Keep using it on later runs. Don't start a new dated file.
- **Check the open entries again first.** On a re-run, check every open entry against the current code before adding anything. Delete entries that are fixed or turned out wrong, and correct the ones that drifted.
- **Each entry stands alone:** a one-line claim, `path:line` evidence, the date found, and its status (`open`, `fixed`, `kept`, `deferred`).
- **When a finding is fixed,** delete it here and add a changelog line with `scripts/add_changelog_line.sh`.
- **A finding that needs a human** (a login, a key, a legal call) also goes in `MANUAL_TODO.md`, and each entry names the other.

Start each file with a short header: what the audit looks for, the command that runs it, and the date of the last full run.

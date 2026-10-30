# Writing scripts

Rules for scripts. The rules in the root `AGENTS.md` apply too.

- **Say what it does at the top.** The first comment line is a one-line description, followed by how to run it.
- **Fail early.** Bash starts with `set -euo pipefail`. Check arguments and print a usage line when they are wrong.
- **Exit codes mean something.** 0 is fine or clean, anything else needs attention.
- **Keep output short.** Cap every list (`head -n 40`). An agent pastes the output into its context, and a script that can print 500 lines is a bug.
- **Plain text only.** No colours, no pagers, no prompts, so agents and CI can run it.
- **Read-only unless the name says otherwise.** A script that changes data, deploys or deletes has a name that says so and asks before it acts.
- **Save repeated work.** If you needed a pipeline of several commands to answer a question about the repo, save it as a script before you finish. List it below.

## Scripts

- `add_changelog_line.sh "<line>"`: adds one dated line to `CHANGELOG.md` without reading the file.
- `check_web_boots.sh <url>`: loads the web app in headless Chrome and fails on any uncaught startup error or no first frame within 20 s. Used by CI and after each deploy.
- `stage_web_build.sh <build-dir> <id>`: moves a `--base-href /b/<id>/` web build into its per-deploy folder, leaving `index.html` and `version.json` at the root. Used by `web.yml`.
- `check_deps.sh`: checks the tools the project needs are installed. Edit the lists at the top.
- `setup_firebase_deploy.sh [--yes]`: one-time Google Cloud setup for keyless GitHub Actions → Firebase Hosting deploys (`.github/workflows/web.yml`). Prints the plan without `--yes`.
- `setup_dev_env.sh`: one-time setup for a fresh clone. Turns on the hooks in `.githooks/` and runs `check_deps.sh`.
- `agent/info_diff.sh [base-ref]`: what changed, in a few lines.
- `agent/info_find.sh <Symbol> [-t]`: where a class, function or type is declared, in most languages, and which files mention it.
- `agent/info_grep.sh <pattern> [path] [-a]`: capped two-phase search. Use it instead of a raw grep over a big folder.
- `agent/info_scripts.sh [keyword]`: every script in the repo and what it does.
- `agent/info_doc_drift.sh [links|paths]`: doc links and paths that point at nothing.

The read-only scripts for agents live in `scripts/agent/`. Its `README.md` has the rules they follow.

Hooks (in `.githooks/`, turned on by `setup_dev_env.sh`): `pre-commit` runs the fast check set at its top, which is empty by default. `pre-push` blocks direct pushes to `main`.

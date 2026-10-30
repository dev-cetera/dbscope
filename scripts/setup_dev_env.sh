#!/usr/bin/env bash
# One-time setup for a fresh clone: turns on the git hooks, then checks your tools. Usage: bash scripts/setup_dev_env.sh
#
# Safe to run again. The only thing it changes is this clone's
# `core.hooksPath`. The hooks in .githooks/ do nothing until that is set, and
# nothing tells you they are off.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

current="$(git config --local core.hooksPath || true)"
if [ "$current" = ".githooks" ]; then
  echo "  git hooks    OK         core.hooksPath=.githooks"
else
  git config core.hooksPath .githooks
  echo "  git hooks    ON         core.hooksPath=.githooks${current:+ (was $current)}"
fi
for hook in .githooks/*; do
  [ -f "$hook" ] && [ ! -x "$hook" ] && chmod +x "$hook" && echo "  fixed        made $hook executable"
done
echo

bash scripts/check_deps.sh

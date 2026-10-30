#!/usr/bin/env bash
# Short summary of what changed: branch, changed files per top folder, diffstat, untracked files. Usage: bash scripts/agent/info_diff.sh [base-ref]
#
# The default base is HEAD, so you see uncommitted work only. Pass a branch
# (origin/main) to see everything on this branch. Read-only.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
base="${1:-HEAD}"

echo "branch $(git branch --show-current) @ $(git rev-parse --short HEAD 2>/dev/null || echo 'no commits')  (base: $base)"
echo
echo "-- changed files by folder --"
{ git diff --name-only "$base" -- 2>/dev/null || true; git ls-files --others --exclude-standard; } \
  | awk -F/ 'NF == 1 { print "(root)"; next } { print $1 }' \
  | sort | uniq -c | sort -rn | head -n 20
echo
echo "-- diffstat --"
git diff --stat "$base" -- 2>/dev/null | tail -n 3 || true
echo
echo "-- untracked (first 15) --"
git ls-files --others --exclude-standard | head -n 15

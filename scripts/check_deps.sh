#!/usr/bin/env bash
# Checks the tools this project needs are installed and prints their versions. Usage: bash scripts/check_deps.sh
#
# Edit the two lists below for your stack. A missing REQUIRED tool fails the
# script. A missing OPTIONAL one only warns. Every tool is checked, so one
# missing tool can't hide the rest.
set -euo pipefail

# name|install hint
REQUIRED="
git|https://git-scm.com/downloads
rg|brew install ripgrep  (or apt install ripgrep)
bash|ships with macOS and Linux, Git Bash on Windows
fvm|brew tap leoafarias/fvm && brew install fvm, then: fvm install
"
OPTIONAL="
gh|brew install gh  (only needed for GitHub work)
actionlint|brew install actionlint  (only needed to edit .github/workflows)
gcloud|https://cloud.google.com/sdk  (only for scripts/setup_firebase_deploy.sh)
"

fail=0 warn=0
check() { # $1 = name, $2 = hint, $3 = MISSING or WARN
  if command -v "$1" >/dev/null 2>&1; then
    printf '  %-12s %-8s %s\n' "$1" OK "$("$1" --version 2>&1 | head -n 1)"
  else
    printf '  %-12s %-8s %s\n' "$1" "$3" "$2"
    return 1
  fi
}

while IFS='|' read -r name hint; do
  [ -n "$name" ] || continue
  check "$name" "$hint" MISSING || fail=$((fail + 1))
done <<LIST
$REQUIRED
LIST
while IFS='|' read -r name hint; do
  [ -n "$name" ] || continue
  check "$name" "$hint" WARN || warn=$((warn + 1))
done <<LIST
$OPTIONAL
LIST

echo
echo "  $fail missing, $warn optional missing"
[ "$fail" -eq 0 ]

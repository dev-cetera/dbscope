#!/usr/bin/env bash
# Every script in the repo and what it does, grouped by folder. Usage: bash scripts/agent/info_scripts.sh [keyword]
#
# The description is the first comment line after the shebang. Covers *.sh,
# *.py, *.mjs, *.js, *.ts and *.rb files outside build and vendor folders,
# including the ones a command keeps in .agents/skills/<name>/scripts/. The
# keyword filters path and description, ignoring case. Capped at SCRIPTS_CAP
# rows (default 120). Exit 0 when something matched, 1 when nothing did.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

keyword="${1:-}"
cap="${SCRIPTS_CAP:-120}"

describe() { # first comment line of a script's header
  awk 'NR > 30 { exit }
    /^#!/ || /coding[:=]/ || /shellcheck/ || /eslint/ { next }
    /^[ \t]*(#|\/\/)[ \t]*[^ \t#\/=-]/ { sub(/^[ \t]*(#+|\/\/+)[ \t]*/, ""); sub(/^@[A-Za-z.]*description[ \t]*/, ""); sub(/ Usage:.*/, ""); print; exit }' "$1"
}

list="$(git ls-files --cached --others --exclude-standard '*.sh' '*.py' '*.mjs' '*.js' '*.ts' '*.rb' \
  | grep -vE '(^|/)(node_modules|build|dist|vendor|\.venv|__pycache__)/' \
  | grep -vE '\.(min|config)\.(js|mjs|ts)$|\.d\.ts$' \
  | awk '{ d = $0; sub(/\/[^\/]*$/, "", d); if (d == $0) d = "."; print d "\t" $0 }' | sort -u | cut -f2 || true)"

shown=0 matched=0 last_dir=""
while IFS= read -r file; do
  [ -n "$file" ] && [ -f "$file" ] || continue
  desc="$(describe "$file")"
  if [ -n "$keyword" ]; then
    grep -qi -- "$keyword" <<<"$file $desc" || continue
  fi
  matched=$((matched + 1))
  [ "$shown" -lt "$cap" ] || continue
  dir="$(dirname "$file")"
  [ "$dir" = "$last_dir" ] || { printf '%s/\n' "$dir"; last_dir="$dir"; }
  printf '  %-30s %s\n' "$(basename "$file")" "$(printf '%s' "$desc" | cut -c1-110)"
  shown=$((shown + 1))
done <<EOF2
$list
EOF2

[ "$matched" -gt "$shown" ] && echo "... $((matched - shown)) more. Pass a keyword or raise SCRIPTS_CAP."
[ "$matched" -gt 0 ]

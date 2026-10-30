#!/usr/bin/env bash
# Two-phase search: list the matching files first, then show a capped handful
# of matches from the first few. Use it instead of a raw content grep, which
# can put 50k tokens into the context. Skips generated code and build output
# (pass -a to include everything). Exit 0 = matches, 1 = none.
#
#   info_grep.sh <pattern> [path] [-a]
#
# Extra globs to skip (big data files, say): DART_SEARCH_EXCLUDE='**/emoji_table.dart,**/l10n/**'
# Runs on macOS bash 3.2: no mapfile, no empty arrays under `set -u`.
set -eo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

pat="${1:-}"
[ -n "$pat" ] || { echo "usage: info_grep.sh <pattern> [path] [-a]"; exit 2; }
dir="./"
all=0
shift
for arg in "$@"; do
  case "$arg" in
    -a) all=1 ;;
    *) dir="$arg" ;;
  esac
done

globs=(-g '!**/build/**' -g '!**/.dart_tool/**' -g '!**/node_modules/**' -g '!CHANGELOG.md')
if [ "$all" -eq 0 ]; then
  globs+=(-g '!**/*.g.dart' -g '!**/*.freezed.dart' -g '!**/*.mocks.dart')
  IFS=',' read -r -a extra <<< "${DART_SEARCH_EXCLUDE:-}"
  for g in "${extra[@]}"; do [ -n "$g" ] && globs+=(-g "!$g"); done
fi

files="$(rg -l --no-messages "${globs[@]}" -e "$pat" "$dir" | sort || true)"
n="$(printf '%s' "$files" | grep -c . || true)"
if [ "${n:-0}" -eq 0 ]; then
  echo "no matches for /$pat/ in $dir"
  exit 1
fi

echo "files: ${n} (first 20)"
printf '%s\n' "$files" | head -20 | sed 's/^/  /'
echo "--- matches (first 3 per file, 8 files, 4000 chars max)"
# One file per line, so paths with spaces survive.
printf '%s\n' "$files" | head -8 | while IFS= read -r f; do
  rg -nH --max-count 3 --max-columns 200 --max-columns-preview -e "$pat" "$f" || true
done | head -c 4000
echo

#!/usr/bin/env bash
# Where is a Dart symbol declared? Prints `file:line  declaration` for every
# class / mixin / enum / extension / typedef named <Symbol>, then the files that
# mention it (capped at 15). Skips tests, generated code and build output
# unless asked. Exit 0 = found, 1 = not found.
#
#   info_find.sh <Symbol> [-t]
#     -t  include tests
#
# Extra globs to skip (big data files, say): DART_SEARCH_EXCLUDE='**/emoji_table.dart,**/l10n/**'
# Runs on macOS bash 3.2: no mapfile, no empty arrays under `set -u`.
set -eo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

sym="${1:-}"
[ -n "$sym" ] || { echo "usage: info_find.sh <Symbol> [-t]"; exit 2; }
shift

with_tests=0
for arg in "$@"; do
  case "$arg" in
    -t) with_tests=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

globs=(-g '*.dart' -g '!**/*.g.dart' -g '!**/*.freezed.dart' -g '!**/*.mocks.dart' -g '!**/build/**' -g '!**/.dart_tool/**')
[ "$with_tests" -eq 1 ] || globs+=(-g '!**/test/**' -g '!**/integration_test/**')
IFS=',' read -r -a extra <<< "${DART_SEARCH_EXCLUDE:-}"
for g in "${extra[@]}"; do [ -n "$g" ] && globs+=(-g "!$g"); done

decl="$(rg -n --no-heading "${globs[@]}" \
  "^\s*((abstract|base|final|sealed|interface|mixin)\s+)*(class|mixin|enum|typedef|extension(\s+type)?)\s+${sym}\b" ./ \
  2>/dev/null || true)"

if [ -z "$decl" ]; then
  echo "not found: $sym (declarations only; for any mention try info_grep.sh '\\b$sym\\b')"
  exit 1
fi

echo "declared:"
printf '%s\n' "$decl" | head -20 | sed 's/^/  /'

refs="$(rg -l -w "${globs[@]}" "$sym" ./ 2>/dev/null || true)"
n="$(printf '%s' "$refs" | grep -c . || true)"
echo "referenced in ${n} files (first 15):"
printf '%s\n' "$refs" | head -15 | sed 's/^/  /'

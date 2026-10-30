#!/usr/bin/env bash
# Points Dart and Flutter packages at the kit's strict analysis_options. Usage: bash .agents/skills/dart-discipline/scripts/use_strict_analysis.sh [package-dir ...] [--all] [--replace] [--dry-run]
#
# For each package (a folder with pubspec.yaml) it adds one line to the
# package's analysis_options.yaml:
#   include: <relative path>/.agents/skills/dart-discipline/analysis_options/flutter.yaml
# flutter.yaml for packages that depend on Flutter, dart.yaml for the rest.
# No analysis_options.yaml yet: it writes one. One without an include: the
# line goes at the top and everything else stays. One that already includes
# something else (say package:flutter_lints/flutter.yaml): it stops and says
# so, unless --replace, which swaps only that line.
#
#   --all       every package in the repo (skips build output and .dart_tool)
#   --dry-run   print what would change
# Exit 0 when every package is set, 1 when one was left alone, 2 on bad usage.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
options_dir="$(cd "$here/../analysis_options" && pwd)"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

replace=0 dry=0 all=0 packages=""
for arg in "$@"; do
  case "$arg" in
    --replace) replace=1 ;;
    --dry-run) dry=1 ;;
    --all) all=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) packages="$packages
$arg" ;;
  esac
done
if [ "$all" = 1 ]; then
  packages="$packages
$(cd "$root" && find . -name pubspec.yaml -not -path '*/build/*' -not -path '*/.dart_tool/*' \
    -not -path '*/.symlinks/*' -not -path '*/ephemeral/*' -not -path './.agents/*' | sed 's#/pubspec.yaml$##')"
fi
[ -n "$(printf '%s' "$packages" | tr -d '[:space:]')" ] || packages="."

relpath() { # relative path from directory $1 to file $2 (both absolute)
  local from="$1" to="$2" up=""
  while [ "${to#"$from"/}" = "$to" ]; do
    from="$(dirname "$from")"
    up="../$up"
  done
  printf '%s%s' "$up" "${to#"$from"/}"
}

status=0
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  case "$pkg" in /*) ;; *) pkg="$root/${pkg#./}" ;; esac
  pkg="${pkg%/.}"
  if [ ! -f "$pkg/pubspec.yaml" ]; then echo "skip $pkg: no pubspec.yaml"; status=1; continue; fi
  pkg="$(cd "$pkg" && pwd)"
  kind=dart
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$pkg/pubspec.yaml" && kind=flutter
  line="include: $(relpath "$pkg" "$options_dir/$kind.yaml")"
  file="$pkg/analysis_options.yaml"
  name="${pkg#"$root"/}"; [ "$pkg" = "$root" ] && name="."

  if [ ! -f "$file" ]; then
    echo "$name: new analysis_options.yaml ($kind)"
    [ "$dry" = 1 ] || printf '# Strict analyzer settings from dart-agent-kit. Switch single rules off below,\n# under linter: rules:, with a comment saying why.\n\n%s\n' "$line" > "$file"
  elif grep -qxF "$line" "$file"; then
    echo "$name: already set ($kind)"
  elif grep -qE '^include:' "$file"; then
    current="$(grep -m1 -E '^include:' "$file")"
    if [ "$replace" = 1 ]; then
      echo "$name: replaced \"$current\" ($kind)"
      [ "$dry" = 1 ] || { awk -v new="$line" '/^include:/ && !done {print new; done=1; next} {print}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"; }
    else
      echo "$name: left alone, it already has \"$current\". Re-run with --replace to swap it."
      status=1
    fi
  else
    echo "$name: added the include ($kind)"
    [ "$dry" = 1 ] || { { printf '%s\n\n' "$line"; cat "$file"; } > "$file.tmp" && mv "$file.tmp" "$file"; }
  fi
done <<< "$packages"
exit "$status"

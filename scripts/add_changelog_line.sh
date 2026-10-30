#!/usr/bin/env bash
# Adds one dated line to CHANGELOG.md without reading the file. Usage: bash scripts/add_changelog_line.sh "<what changed, for whom>"
#
# The line goes first under today's `## YYYY-MM-DD` heading, with the date
# repeated at the end so it still makes sense when quoted on its own. If today
# has no heading yet, one is added at the top of the dated list, just below the
# header's `---` line. The file is written to a temp copy and moved into place,
# so two sessions adding lines at once don't corrupt it.
#
# Never check for an existing line first. A duplicate costs nothing, and
# reading a long changelog costs an agent thousands of tokens.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 \"<one-line description of the change>\"" >&2
  exit 2
fi

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
FILE="$ROOT/CHANGELOG.md"
[ -f "$FILE" ] || { echo "add_changelog_line: $FILE is missing" >&2; exit 1; }
TODAY="$(date +%F)"
ENTRY="- $1 ($TODAY)"
TMP="$(mktemp "$ROOT/.changelog.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk -v heading="## $TODAY" -v entry="$ENTRY" '
  { lines[NR] = $0; if ($0 == heading) have_today = 1 }
  END {
    for (i = 1; i <= NR; i++) {
      print lines[i]
      if (done) continue
      if (have_today && lines[i] == heading) {
        # The heading is followed by one blank line, then the entries.
        if (i + 1 <= NR && lines[i + 1] == "") { print ""; i++ }
        print entry
        done = 1
      } else if (!have_today && lines[i] == "---") {
        print ""
        print heading
        print ""
        print entry
        done = 1
      }
    }
    if (!done) { print "add_changelog_line: CHANGELOG.md needs a --- line under its header" > "/dev/stderr"; exit 1 }
  }
' "$FILE" > "$TMP"

mv "$TMP" "$FILE"
trap - EXIT
echo "added under ## $TODAY: $ENTRY"

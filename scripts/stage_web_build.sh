#!/usr/bin/env bash
# Moves a `flutter build web --base-href /b/<id>/` output into its per-deploy folder. Usage: bash scripts/stage_web_build.sh <build-dir> <id>
#
# Why: the first deploys served every .js/.json `max-age=31536000, immutable`,
# so browsers that visited then never re-ask for /main.dart.js or
# /flutter_bootstrap.js, whatever the server says now. A new URL per deploy is
# the only thing that reaches them. So everything goes under /b/<id>/ and only
# these stay at the root:
#   index.html                 entry point (served no-store), points at /b/<id>/
#   version.json               polled by open tabs for the Refresh prompt
#   flutter_service_worker.js  Flutter's self-unregistering worker, for browsers
#                              that registered the old one at this URL
# Changes files in <build-dir> only.
set -euo pipefail

dir="${1:?usage: stage_web_build.sh <build-dir> <id>}"
id="${2:?usage: stage_web_build.sh <build-dir> <id>}"
[[ "$id" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "stage_web_build: bad id '$id'" >&2; exit 2; }
[ -f "$dir/index.html" ] || { echo "stage_web_build: no index.html in $dir" >&2; exit 2; }
grep -q "<base href=\"/b/$id/\">" "$dir/index.html" ||
  { echo "stage_web_build: $dir was not built with --base-href /b/$id/" >&2; exit 1; }

dest="$dir/b/$id"
mkdir -p "$dest"
for entry in "$dir"/* "$dir"/.[!.]*; do
  [ -e "$entry" ] || continue
  [ "$entry" = "$dir/b" ] && continue
  mv "$entry" "$dest/"
done
cp "$dest/index.html" "$dest/version.json" "$dir/"
if [ -f "$dest/flutter_service_worker.js" ]; then
  cp "$dest/flutter_service_worker.js" "$dir/"
fi
echo "Staged $dir/b/$id ($(find "$dest" -type f | wc -l | tr -d ' ') files)"

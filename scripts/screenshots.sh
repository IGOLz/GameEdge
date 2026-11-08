#!/bin/zsh
# Captures every page of the Dev app with sample displays, in light and dark,
# into build/screenshots. The real displays are never touched (GAMEEDGE_DEBUG_SAMPLE=1).
# Needs Screen Recording permission for the terminal.
# Usage: scripts/screenshots.sh [page ...]   (default: every page)
set -euo pipefail
cd "${0:A:h}/.."
APP="build/dd-dev/Build/Products/Debug/GameEdge Dev.app"
[[ -d "$APP" ]] || { echo "Build the Dev app first: scripts/dev-app.sh" >&2; exit 1; }
OUT=build/screenshots
mkdir -p "$OUT"
if (( $# )); then pages=("$@"); else pages=(overview games layout general); fi
window_id() {
  /usr/bin/swift -e 'import CoreGraphics
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
  if let w = list.first(where: { ($0["kCGWindowOwnerName"] as? String) == "GameEdge Dev" && ($0["kCGWindowLayer"] as? Int) == 0 }) { print(w["kCGWindowNumber"]!) }'
}
for appearance in light dark; do
  for page in $pages; do
    pkill -x "GameEdge Dev" 2>/dev/null || true
    sleep 0.5
    GAMEEDGE_DEBUG_SAMPLE=1 GAMEEDGE_DEBUG_PAGE=$page GAMEEDGE_DEBUG_APPEARANCE=$appearance \
      "$APP/Contents/MacOS/GameEdge Dev" >/dev/null 2>&1 &
    sleep 2.5
    id=$(window_id)
    [[ -n "$id" ]] || { echo "No window for $page" >&2; exit 1; }
    screencapture -o -x -l "$id" "$OUT/$page-$appearance.png"
    echo "$OUT/$page-$appearance.png"
  done
done
pkill -x "GameEdge Dev" 2>/dev/null || true

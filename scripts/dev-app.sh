#!/bin/zsh
# Builds the Debug app "GameEdge Dev" (bundle ID dev.igol.GameEdge.Dev, DEV icon,
# own preferences and login item, no self-updates), signs it with the
# Developer ID, installs it in /Applications and opens it.
# The installed GameEdge is never touched. Quit it first if you test game
# detection with both running: they would both move the displays.
set -euo pipefail
cd "${0:A:h}/.."
APP="GameEdge Dev"
PRODUCT="build/dd-dev/Build/Products/Debug/$APP.app"
DEST="/Applications/$APP.app"
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
echo "→ Building $APP (log: build/dev-build.log)"
mkdir -p build
if ! xcodebuild -project GameEdge.xcodeproj -scheme GameEdge -configuration Debug \
  -derivedDataPath build/dd-dev -clonedSourcePackagesDirPath build/SourcePackages build >build/dev-build.log 2>&1; then
  grep -E "error:" build/dev-build.log | head -20 >&2 || true
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCT/Contents/Info.plist")" == dev.igol.GameEdge.Dev ]] \
  || { echo "The Debug build doesn't have the Dev bundle ID." >&2; exit 1; }
codesign --verify --deep --strict "$PRODUCT"
pkill -x "$APP" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$PRODUCT" "$DEST"
[[ "${1:-}" == "--no-open" ]] || open "$DEST"
echo "✓ $DEST"

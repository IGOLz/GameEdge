#!/bin/zsh
# Builds GameEdge (Release, for this Mac) and installs it into /Applications.
# For a signed, notarized universal build use scripts/release.sh.
set -euo pipefail
cd "${0:A:h}/.."
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
mkdir -p build
xcodebuild -project GameEdge.xcodeproj -scheme GameEdge -configuration Release \
  -derivedDataPath build/dd-release -clonedSourcePackagesDirPath build/SourcePackages \
  ONLY_ACTIVE_ARCH=YES "$@" build >build/install-build.log 2>&1 \
  || { grep -E "error:" build/install-build.log | head -20 >&2; exit 1; }
APP=build/dd-release/Build/Products/Release/GameEdge.app
# Quit a running copy (it restores the normal layout), then replace it.
osascript -e 'tell application id "dev.igol.GameEdge" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/GameEdge.app
ditto "$APP" /Applications/GameEdge.app
open /Applications/GameEdge.app
echo "✓ /Applications/GameEdge.app"

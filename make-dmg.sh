#!/bin/bash
# Package the built app into a distributable .dmg with a drag-to-Applications layout.
# Run ./build.sh first — this only wraps build/HeyDebby.app, it does not compile.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HeyDebby.app"
DMG="build/HeyDebby.dmg"
VOL="HeyDebby"

[ -d "$APP" ] || { echo "No $APP — run ./build.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -ov "$DMG" >/dev/null

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
# The app is ad-hoc signed (no Developer ID / notarization), so Gatekeeper will block a
# double-click on another Mac. Testers open it once with: right-click → Open, or run
#   xattr -dr com.apple.quarantine /Applications/HeyDebby.app
echo "Note: ad-hoc signed — testers right-click → Open, or clear the quarantine flag."

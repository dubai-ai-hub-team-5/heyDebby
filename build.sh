#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Debug first: `assert` is compiled out of release builds, so --selfcheck only bites here.
swift build
.build/debug/HeyDebby --selfcheck

swift build -c release

APP=build/HeyDebby.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HeyDebby "$APP/Contents/MacOS/HeyDebby"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HeyDebby</string>
    <key>CFBundleDisplayName</key><string>HeyDebby</string>
    <key>CFBundleIdentifier</key><string>local.heydebby.clone</string>
    <key>CFBundleExecutable</key><string>HeyDebby</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Debby listens when you talk to it.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Debby transcribes your voice questions.</string>
</dict>
</plist>
EOF
# TCC binds Accessibility/Screen Recording grants to the signature. Ad-hoc signing
# re-hashes the binary every build, so every build looks like a new app and macOS
# asks for permission again. A real cert keeps the identity stable across rebuilds.
ID=$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP (signed with ${ID:-ad-hoc — permissions will reset every build})"
echo "Run: open $APP"

#!/usr/bin/env bash
# Assemble a .app around the SwiftPM executable.
#
#     ./Scripts/bundle.sh [debug|release]
#
# SwiftPM builds a bare binary; a menu bar app needs a bundle for two reasons
# that are not cosmetic. `LSUIElement` is what keeps it out of the Dock, and
# `Contents/Resources` is where `NSImage(named:)` looks — under a bare
# `swift run` there is no bundle, the glyph falls back to an SF Symbol, and the
# app icon does not exist at all.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/AwtrixConnectors.app"

swift build -c "$CONFIG" --product AwtrixConnectorsApp
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/AwtrixConnectorsApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AwtrixConnectors"

# The artwork is generated, never committed: build/ is git-ignored, so the only
# thing under version control is the code that draws it. Deterministic by
# construction — every lit pixel comes from a hash of its own coordinates — so a
# diff in the art means someone changed the design.
swift Scripts/MakeIcon.swift
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# The menu bar glyph, at 1x/2x/3x and in both device states. Loose PNGs rather
# than an asset catalogue: `NSImage(named:)` finds them in Resources, and
# compiling a catalogue would drag actool into a package that has no Xcode
# project.
cp build/icon/MenuBarIcon*.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AwtrixConnectors</string>
  <key>CFBundleIdentifier</key><string>dev.artk0re.awtrix-connectors</string>
  <key>CFBundleName</key><string>AwtrixConnectors</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "built $APP"

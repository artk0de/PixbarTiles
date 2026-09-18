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
APP="build/PixelClockTiles.app"

swift build -c "$CONFIG" --product PixelClockTilesApp
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_PATH/PixelClockTilesApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PixelClockTiles"

# The kit's resources (the bundled GIFs), as SwiftPM built them. Without this
# copy the app finds them only through the absolute build path compiled into
# the binary, and SwiftPM's lookup stops the process once that directory is
# gone — a build installed from a worktree dies with the worktree.
# `KitResources` reads this copy first. `Contents/Resources` rather than the
# `.app` root, where SwiftPM would look on its own: codesign refuses anything
# at the root but `Contents`. The name is SwiftPM's, package then target; a
# rename makes this `cp` fail rather than ship an app with no art.
cp -R "$BIN_PATH/PixelClockTiles_PixelClockKit.bundle" "$APP/Contents/Resources/"

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
  <key>CFBundleExecutable</key><string>PixelClockTiles</string>
  <key>CFBundleIdentifier</key><string>dev.artk0re.pixelclocktiles</string>
  <key>CFBundleName</key><string>PixelClockTiles</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <!-- Shown in the Local Network prompt macOS raises the first time the app
       browses for Bonjour services. Without this key the prompt still appears,
       with generic wording and no clue why a clock app wants the network — and
       a refusal is permanent until it is changed in System Settings, which is
       exactly the answer the panel has to be able to tell apart from an empty
       network. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>PixelClockTiles looks for pixel clocks on your network, so you do not have to type their address yourself.</string>
  <!-- Required, and not merely for the wording: without this key
       `INFocusStatusCenter.requestAuthorization` does not fail, it ABORTS the
       process — EXC_CRASH, TCC namespace, "must contain an
       NSFocusStatusUsageDescription key". `SystemFocusStatus` refuses to ask
       when it is missing, so a bundle built without it degrades to the quiet
       window rather than crashing; this is what makes the other half reachable
       the day the app is signed. -->
  <key>NSFocusStatusUsageDescription</key>
  <string>PixelClockTiles checks whether a Focus is on, so it stays quiet instead of reading a joke out loud while you are busy.</string>
  <!-- Without this key CoreLocation refuses whatever the signature says, so it
       has to be here before location is worth attempting at all. It IS worth
       attempting: measured on a signed probe from this bundle's own signing
       identity, `requestWhenInUseAuthorization` moved the status from
       notDetermined to authorized and `requestLocation` returned a fix to 55
       metres. That defeats the two things that make the alternatives useless
       here — a VPN, which puts IP geolocation 2,000 km out, and a geocoder that
       only knows settlements, which cannot tell one side of a 40 km city from
       the other. -->
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>PixelClockTiles reads this Mac's location once, when you ask it to, so the clock shows the weather where you actually are.</string>
</dict>
</plist>
PLIST

echo "built $APP"

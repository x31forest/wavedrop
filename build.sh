#!/bin/zsh
# Builds Wavedrop.app into ./build (release, ad-hoc signed).
set -e
cd "${0:a:h}"

swift build -c release
APP=build/Wavedrop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Wavedrop "$APP/Contents/MacOS/Wavedrop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wavedrop</string>
    <key>CFBundleDisplayName</key><string>Wavedrop</string>
    <key>CFBundleIdentifier</key><string>local.wavedrop.visualizer</string>
    <key>CFBundleExecutable</key><string>Wavedrop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Wavedrop asks Spotify for the current song and album art to show over the visuals.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Wavedrop listens to the music playing on your Mac to drive the visuals. Audio never leaves your computer.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

# Install into /Applications (quit a running copy first so it can be replaced).
if [[ "$1" != "--no-install" ]]; then
    pkill -x Wavedrop && sleep 1 || true
    rm -rf /Applications/Wavedrop.app
    ditto "$APP" /Applications/Wavedrop.app
    echo "Installed /Applications/Wavedrop.app"
fi

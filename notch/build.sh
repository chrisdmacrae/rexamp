#!/bin/sh
# Builds RexNotch.app with amp-rex-hud inside it. Pass --install to copy it
# to ~/Applications, open it, and have it open at login.
set -eu
cd "$(dirname "$0")"
app=build/RexNotch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swift build -c release --product RexNotch
cp "$(swift build -c release --show-bin-path)/RexNotch" "$app/Contents/MacOS/"
(cd .. && go build -o "notch/$app/Contents/MacOS/amp-rex-hud" .)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RexNotch</string>
  <key>CFBundleIdentifier</key><string>com.chrisdmacrae.rexnotch</string>
  <key>CFBundleExecutable</key><string>RexNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo "built $app"
if [ "${1:-}" = "--install" ]; then
  pkill -x RexNotch || true
  rm -rf ~/Applications/RexNotch.app
  mkdir -p ~/Applications
  cp -R "$app" ~/Applications/
  open ~/Applications/RexNotch.app --args --open-at-login
fi

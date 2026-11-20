#!/bin/sh
# Builds RexNotch.app with amp-rex-hud inside it. Pass --install to copy it
# to ~/Applications, open it, and have it open at login. Pass --universal
# to build for both Apple Silicon and Intel (used for GitHub releases).
set -eu
install_app=false
universal=false
for arg in "$@"; do
  case "$arg" in
    --install) install_app=true ;;
    --universal) universal=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
cd "$(dirname "$0")"
app=build/RexNotch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
set --
if "$universal"; then
  set -- --arch arm64 --arch x86_64
fi
swift build -c release --product RexNotch "$@"
cp "$(swift build -c release --show-bin-path "$@")/RexNotch" "$app/Contents/MacOS/"
if "$universal"; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  for arch in arm64 amd64; do
    (cd .. && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags='-s -w' -o "$tmp/amp-rex-hud-$arch" .)
  done
  lipo -create "$tmp/amp-rex-hud-arm64" "$tmp/amp-rex-hud-amd64" -output "$app/Contents/MacOS/amp-rex-hud"
else
  (cd .. && go build -o "notch/$app/Contents/MacOS/amp-rex-hud" .)
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RexNotch</string>
  <key>CFBundleIdentifier</key><string>com.chrisdmacrae.rexnotch</string>
  <key>CFBundleExecutable</key><string>RexNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo "built $app"
if "$install_app"; then
  pkill -x RexNotch || true
  rm -rf ~/Applications/RexNotch.app
  mkdir -p ~/Applications
  cp -R "$app" ~/Applications/
  open ~/Applications/RexNotch.app --args --open-at-login
fi

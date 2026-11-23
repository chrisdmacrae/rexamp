#!/bin/sh
# Install release binaries without sudo. VERSION may be a tag (e.g. v0.1.0).
set -eu

fail() { echo "Error: $*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || fail 'curl is required'
case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *) fail 'Supported systems: macOS, Linux, and Windows (Git Bash)' ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64|AMD64) arch=amd64 ;;
  *) fail 'Supported architectures: arm64 and x64' ;;
esac
if [ "$os" = darwin ]; then
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 14 ] || fail 'RexNotch requires macOS 14 or newer'
  app_dir=${APP_DIR:-"$HOME/Applications"}
  [ ! -e "$app_dir/RexNotch.app" ] || fail "Quit RexNotch and remove $app_dir/RexNotch.app before reinstalling"
fi
if command -v sha256sum >/dev/null 2>&1; then
  hash=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  hash='shasum -a 256'
else
  fail 'sha256sum or shasum is required to verify downloads'
fi

base=https://github.com/chrisdmacrae/rexnotch/releases
if [ -n "${VERSION:-}" ]; then
  base="$base/download/$VERSION"
else
  # Resolve latest once so a new release cannot mix assets from two versions.
  latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$base/latest")
  tag=${latest##*/}
  [ "$tag" != latest ] && [ -n "$tag" ] || fail 'No published release found'
  base="$base/download/$tag"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt"
download() {
  echo "Downloading $1..."
  curl -fsSL "$base/$1" -o "$tmp/$1"
  expected=$(awk -v name="$1" '$2 == name {print $1}' "$tmp/checksums.txt")
  [ -n "$expected" ] || fail "No checksum for $1"
  actual=$($hash "$tmp/$1" | awk '{print $1}')
  [ "$actual" = "$expected" ] || fail "Checksum mismatch for $1"
}

binary=rex-hud
asset="rex-hud_${os}_${arch}"
if [ "$os" = windows ]; then
  command -v unzip >/dev/null 2>&1 || fail 'unzip is required'
  binary=$binary.exe
  download "$asset.zip"
  unzip -q "$tmp/$asset.zip" -d "$tmp/cli"
else
  download "$asset.tar.gz"
  mkdir "$tmp/cli"
  tar -xzf "$tmp/$asset.tar.gz" -C "$tmp/cli"
fi
if [ "$os" = darwin ]; then
  download RexNotch_macos_universal.zip
  ditto -x -k "$tmp/RexNotch_macos_universal.zip" "$tmp/app"
  codesign --verify --deep --strict "$tmp/app/RexNotch.app"
fi

bin_dir=${BIN_DIR:-"$HOME/.local/bin"}
mkdir -p "$bin_dir"
install -m 755 "$tmp/cli/$binary" "$bin_dir/$binary"
echo "Installed $bin_dir/$binary"
# The CLI was named amp-rex-hud; point an old install at the new one.
old="$bin_dir/amp-rex-hud"
if [ "$os" != windows ] && [ -f "$old" ] && [ ! -L "$old" ]; then
  ln -sf "$binary" "$old"
  echo "Linked $old to $binary"
fi
if [ "$os" = darwin ]; then
  mkdir -p "$app_dir"
  ditto "$tmp/app/RexNotch.app" "$app_dir/RexNotch.app"
  echo "Installed $app_dir/RexNotch.app"
  echo 'This app is ad-hoc signed, not notarized by Apple.'
  echo 'If macOS blocks it, use System Settings > Privacy & Security > Open Anyway.'
  echo "Open with: open \"$app_dir/RexNotch.app\""
fi
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) printf 'Add this directory to your PATH: %s\n' "$bin_dir" ;;
esac

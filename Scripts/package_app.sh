#!/usr/bin/env bash
# Build the Rust core and the app, and assemble a signed Readout.app.
#
# Signed ad hoc unless APP_IDENTITY names a Developer ID certificate, in which
# case it is signed for notarization instead.
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=Readout
BUNDLE_ID=com.thomas.readout
MACOS_MIN_VERSION=14.0
APP_IDENTITY=${APP_IDENTITY:-}

# Apple silicon only: Package.swift links the aarch64 build of the Rust core,
# and the thermal sensors are read the Apple silicon way.
ARCH=arm64
if [[ "$(uname -m)" != "$ARCH" ]]; then
  echo "ERROR: Readout builds on Apple silicon only (this is $(uname -m))" >&2
  exit 1
fi

# A release build sets the version from its tag. Anything else takes the newest
# tag it was built on, so a local build never reports its own release as an
# update — which a fixed default in a file would, the moment a release passed it.
if [[ -z "${MARKETING_VERSION:-}" ]]; then
  LATEST_TAG=$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
  MARKETING_VERSION=${LATEST_TAG#v}
  MARKETING_VERSION=${MARKETING_VERSION:-0.0.0}
fi
BUILD_NUMBER=${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}

ARCHES=$ARCH "$ROOT/Scripts/build_rust.sh" "$CONF"
swift build -c "$CONF" --arch "$ARCH"

# SwiftPM's newer build system writes to .build/out/Products/<Conf>, the older
# one to .build/<arch>-apple-macosx/<conf>, so ask rather than guess.
BINARY="$(swift build -c "$CONF" --arch "$ARCH" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: missing $APP_NAME build at $BINARY" >&2
  exit 1
fi

APP="$ROOT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The icon is drawn from source and not checked in, so a fresh clone would
# otherwise package an app with no icon at all.
ICON="$ROOT/Icon.icns"
if [[ ! -f "$ICON" ]]; then
  "$ROOT/Scripts/make_icon.sh"
fi
cp "$ICON" "$APP/Contents/Resources/Icon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>$(date -u +"%Y-%m-%dT%H:%M:%SZ")</string>
    <key>GitCommit</key><string>$(git rev-parse --short HEAD 2>/dev/null || echo unknown)</string>
</dict>
</plist>
PLIST

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Extended attributes leave AppleDouble files behind that break code sealing.
chmod -R u+w "$APP"
xattr -cr "$APP"
find "$APP" -name '._*' -delete

if [[ -n "$APP_IDENTITY" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "Created $APP"

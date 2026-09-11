#!/usr/bin/env bash
# Package Readout.app and wrap it for download: a disk image to drag into
# Applications, a zip for anyone scripting an install, and their checksums.
#
# MARKETING_VERSION and BUILD_NUMBER in the environment override the version
# package_app.sh would otherwise take from the newest tag.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=Readout
APP="$ROOT/$APP_NAME.app"
DIST="$ROOT/dist"

# Apple silicon only: Package.swift links the aarch64 build of the Rust core,
# and the thermal sensors are read the Apple silicon way.
ARCHES=arm64 "$ROOT/Scripts/package_app.sh" release

codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> $APP_NAME $VERSION ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

rm -rf "$DIST"
mkdir -p "$DIST"

# ditto, not zip: zip drops the bundle's extended attributes and resource forks
# and the signature no longer verifies once it is unpacked.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME-$VERSION.zip"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# hdiutil on a busy machine sometimes fails with "Resource busy"; it succeeds
# on a second try often enough that retrying beats failing the release.
for attempt in 1 2 3; do
  if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
      "$DIST/$APP_NAME-$VERSION.dmg"; then
    break
  fi
  if [[ $attempt -eq 3 ]]; then
    echo "ERROR: hdiutil failed three times" >&2
    exit 1
  fi
  sleep 5
done

( cd "$DIST" && shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION.zip" > SHA256SUMS )
cat "$DIST/SHA256SUMS"

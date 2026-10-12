#!/bin/bash
# Installs or updates Readout from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/readout/main/Scripts/install.sh | bash
#
# Only uses what ships with macOS (curl, ditto, xattr, defaults, open). The latest tag comes from
# the releases/latest redirect rather than the GitHub API, whose 60 anonymous requests an hour are
# shared by everyone behind the same IP.
set -euo pipefail

REPO="bonkedbythonk/readout"
INSTALL_DIR="${READOUT_INSTALL_DIR:-/Applications}"
# READOUT_NO_OPEN=1 skips launching the app, for testing the script itself.

say() { printf '%s\n' "$*"; }

if [ "$(uname -m)" != "arm64" ]; then
    say "Readout needs an Apple silicon Mac. This Mac is $(uname -m)."
    exit 1
fi

# Standard (non-admin) accounts can't write /Applications. ~/Applications is where macOS
# puts per-user apps, and Spotlight finds them there too.
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    say "Installing to $INSTALL_DIR, since this account can't write to /Applications."
fi
APP="$INSTALL_DIR/Readout.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Finding the latest release…"
TAG="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||')"
case "$TAG" in
    v*) VERSION="${TAG#v}" ;;
    *)
        say "Couldn't find the latest release. Get it by hand from"
        say "  https://github.com/$REPO/releases"
        exit 1
        ;;
esac

say "Downloading Readout $VERSION…"
if ! curl -fL --progress-bar -o "$TMP/Readout.zip" \
    "https://github.com/$REPO/releases/download/$TAG/Readout-$VERSION.zip"; then
    say "The download didn't work. Check your connection, or get it by hand from"
    say "  https://github.com/$REPO/releases"
    exit 1
fi

ditto -x -k "$TMP/Readout.zip" "$TMP"
if [ ! -d "$TMP/Readout.app" ]; then
    say "The download doesn't contain Readout.app. Please report it at https://github.com/$REPO/issues"
    exit 1
fi

# Quit a running copy so the update can replace it.
if [ -z "${READOUT_NO_OPEN:-}" ] && pgrep -xq Readout; then
    say "Quitting the running Readout…"
    osascript -e 'tell application "Readout" to quit' >/dev/null 2>&1 || pkill -x Readout || true
    sleep 1
fi

rm -rf "$APP"
ditto "$TMP/Readout.app" "$APP"
# Readout isn't notarized. Without this, macOS blocks the first launch and you'd have to
# allow it in System Settings, Privacy & Security.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "Installed Readout $VERSION in $INSTALL_DIR. It lives in the menu bar, with no Dock icon."

[ -n "${READOUT_NO_OPEN:-}" ] || open "$APP"

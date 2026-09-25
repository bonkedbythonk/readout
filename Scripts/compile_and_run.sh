#!/usr/bin/env bash
# Stop this checkout's running copy, package it again, and launch it.
#
# Only a copy started from this checkout is stopped. An installed Readout in
# /Applications shares the bundle identifier and the process name, so matching
# on either quit that too.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=Readout
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
RUN_TESTS=0

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --help|-h)
      log "Usage: $(basename "$0") [--test]"
      log "  --test  run the Rust core's unit tests first"
      exit 0
      ;;
    *) fail "unknown option ${arg}" ;;
  esac
done

# pkill matches a regular expression, so the checkout's path is escaped.
ROOT_PATTERN="^$(printf '%s' "${ROOT_DIR}" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
BUNDLE_PATTERN="${ROOT_PATTERN}/${APP_NAME}\\.app/Contents/MacOS/${APP_NAME}$"
# A binary run straight from the build folder, wherever SwiftPM put it.
BUILD_PATTERN="${ROOT_PATTERN}/\\.build/.*/${APP_NAME}$"

log "==> Stopping this checkout's ${APP_NAME}"
pkill -f "${BUNDLE_PATTERN}" 2>/dev/null || true
pkill -f "${BUILD_PATTERN}" 2>/dev/null || true

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> cargo test"
  ( cd "${ROOT_DIR}/core" && cargo test --release )
fi

log "==> package app"
"${ROOT_DIR}/Scripts/package_app.sh" release

log "==> launch app"
open "${APP_BUNDLE}"

for _ in {1..10}; do
  if pgrep -f "${BUNDLE_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."

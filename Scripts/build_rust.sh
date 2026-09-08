#!/usr/bin/env bash
# Build the Rust metrics core as a static lib for each requested arch.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONF=${1:-release}
ARCH_LIST=( ${ARCHES:-$(uname -m)} )

for ARCH in "${ARCH_LIST[@]}"; do
  case "$ARCH" in
    arm64)  RUST_TARGET=aarch64-apple-darwin ;;
    x86_64) RUST_TARGET=x86_64-apple-darwin ;;
    *) echo "ERROR: unsupported arch $ARCH" >&2; exit 1 ;;
  esac
  if ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
    echo "ERROR: rust target $RUST_TARGET not installed. Run: rustup target add $RUST_TARGET" >&2
    exit 1
  fi
  echo "==> cargo build ($RUST_TARGET, $CONF)"
  ( cd "$ROOT/core" && cargo build --target "$RUST_TARGET" $([[ "$CONF" == release ]] && echo --release) )

  # SwiftPM has no idea the static library exists, so it will happily reuse a
  # binary linked against an older copy. Drop the executable whenever the
  # library's contents change and SwiftPM links again.
  LIB="$ROOT/core/target/$RUST_TARGET/$CONF/libreadout_core.a"
  STAMP="$ROOT/.build/rust-$RUST_TARGET-$CONF.stamp"
  mkdir -p "$(dirname "$STAMP")"
  NEW_SUM=$(shasum -a 256 "$LIB" | cut -d' ' -f1)
  if [[ "$(cat "$STAMP" 2>/dev/null || true)" != "$NEW_SUM" ]]; then
    rm -f "$ROOT/.build/$ARCH-apple-macosx/$CONF/Readout" "$ROOT/.build/$CONF/Readout"
    printf '%s' "$NEW_SUM" > "$STAMP"
  fi
done

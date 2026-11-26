#!/bin/bash
# Install the serialized-request fix for XeCompilerAdapter (Graphics 0.4.4/0.4.5, Darwin 23-25).
# Usage: sudo bash install-adapter-fix.sh [path-to-adapter.dylib]
set -euo pipefail

SRC="${1:-$(dirname "$0")/adapter.dylib}"
DST="/Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib"
BACKUP_DIR="$HOME/xe-adapter-backup"
EXPECT_ORIG="11609123ce5b930aee500736f8bd504cd0280c37654f8e9f353fcc9fc876aff0"
EXPECT_PATCHED="1f064c6d7db4d966d19053c73610e602f10cdc118185dd03a4e2bcbecbf44ca3"

[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
[ -f "$SRC" ] || { echo "Missing $SRC"; exit 1; }
[ -f "$DST" ] || { echo "Missing $DST (Graphics not installed?)"; exit 1; }

src_hash=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
[ "$src_hash" = "$EXPECT_PATCHED" ] || { echo "ERROR: $SRC sha256 mismatch: $src_hash"; exit 2; }

dst_hash=$(shasum -a 256 "$DST" | cut -d' ' -f1)
if [ "$dst_hash" = "$EXPECT_PATCHED" ]; then
    echo "Already patched, nothing to do."
    exit 0
fi
if [ "$dst_hash" != "$EXPECT_ORIG" ]; then
    echo "ERROR: installed adapter is neither known orig nor patched ($dst_hash)."
    echo "Refusing to overwrite an unknown version. Investigate first."
    exit 3
fi

mkdir -p "$BACKUP_DIR"
cp -p "$DST" "$BACKUP_DIR/adapter.dylib.orig.$(date +%Y%m%d-%H%M%S)"
cp "$SRC" "$DST"
codesign -f -s - "$DST"
killall -9 MTLCompilerService 2>/dev/null || true
echo "Installed. Verify: open Atoll + Photos, then:"
echo "  log show --last 5m --predicate 'eventMessage CONTAINS \"Xe compiler\"' | grep -c abort"
echo "Rollback: sudo cp $BACKUP_DIR/adapter.dylib.orig.<timestamp> $DST && sudo killall -9 MTLCompilerService"
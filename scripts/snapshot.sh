#!/bin/bash
#
# snapshot.sh — renders the app's screens to PNG without a display, for visual
# review. Uses the same SDK probe as build.sh and the same sources, compiled
# with -DSNAPSHOT so Snapshot.swift supplies the entry point.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="$(cat build/.sdk 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk)"
mkdir -p build/snapshots build/modulecache

SOURCES=()
while IFS= read -r -d '' file; do
  SOURCES+=("$file")
done < <(find "$ROOT/BitChord" -name '*.swift' -print0 | sort -z)

xcrun swiftc -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
  -parse-as-library -DSNAPSHOT -Onone \
  -module-cache-path "$ROOT/build/modulecache" \
  -framework AppKit -framework AVFoundation -framework MediaPlayer \
  -framework CoreText -framework CoreGraphics \
  "${SOURCES[@]}" -o build/snapshot 2>&1 | grep -E "error:" | head -30 || true

if [[ ! -x build/snapshot ]]; then
  echo "snapshot build failed" >&2
  exit 1
fi

./build/snapshot

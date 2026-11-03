#!/bin/bash
#
# build.sh — builds BitChord.app for Apple Silicon with nothing but the
# Xcode Command Line Tools. No Xcode project, no SwiftPM, no Xcode.app.
#
#   ./scripts/build.sh            # release build into dist/BitChord.app
#   ./scripts/build.sh --run      # build, then launch it
#   ./scripts/build.sh --debug    # unoptimised, faster to rebuild while editing
#
# The CommandLineTools that ship with macOS 26 carry a Swift compiler that
# cannot build the SDK it ships with (the .swiftinterface in MacOSX26.5.sdk was
# built by a newer compiler than the one bundled). The script probes the
# installed SDKs and picks the newest one that actually compiles, which is
# MacOSX15.4.sdk on this machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="BitChord"
BUNDLE_ID="in.kushagrasingh.bitchord.macos"
VERSION="2.0"
BUILD_NUMBER="200"
MIN_MACOS="14.0"
TARGET="arm64-apple-macos${MIN_MACOS}"

MODE="release"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) MODE="debug" ;;
    --run) RUN=1 ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done

# --- SDK selection -----------------------------------------------------------
# Prefer a cached choice; otherwise probe each installed SDK with a one-line
# SwiftUI compile and keep the first that succeeds.
CACHE="$ROOT/build/.sdk"
SDK=""
if [[ -f "$CACHE" ]] && [[ -d "$(cat "$CACHE")" ]]; then
  SDK="$(cat "$CACHE")"
fi

probe_sdk() {
  local sdk="$1"
  local probe
  probe="$(mktemp -t bitchordprobe).swift"
  cat > "$probe" <<'EOF'
import SwiftUI
@available(macOS 26.0, *)
func glass<V: View>(_ v: V) -> some View { v.glassEffect(.regular, in: .rect(cornerRadius: 8)) }
let v = Text("probe")
EOF
  if xcrun swiftc -sdk "$sdk" -target "$TARGET" -module-cache-path "$ROOT/build/modulecache" \
      -typecheck "$probe" >/dev/null 2>&1; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

if [[ -z "$SDK" ]]; then
  for candidate in \
      /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk \
      "$(xcrun --show-sdk-path)"; do
    if [[ -d "$candidate" ]] && probe_sdk "$candidate"; then
      SDK="$candidate"
      break
    fi
  done
fi

if [[ -z "$SDK" ]]; then
  echo "error: no macOS SDK could compile SwiftUI with this toolchain." >&2
  echo "       Install Xcode, or a matching Command Line Tools package." >&2
  exit 1
fi
mkdir -p "$ROOT/build"
echo "$SDK" > "$CACHE"
echo "→ SDK: $SDK"

# --- Compile -----------------------------------------------------------------
APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r -d '' file; do
  SOURCES+=("$file")
done < <(find "$ROOT/BitChord" -name '*.swift' -print0 | sort -z)

mkdir -p "$ROOT/build/modulecache"

FLAGS=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -parse-as-library
       -module-cache-path "$ROOT/build/modulecache"
       -Xlinker -dead_strip -framework AppKit -framework AVFoundation
       -framework MediaPlayer -framework CoreText -framework CoreGraphics)
if [[ "$MODE" == "release" ]]; then
  FLAGS+=(-O -whole-module-optimization)
else
  FLAGS+=(-Onone -g)
fi

echo "→ Compiling ${#SOURCES[@]} Swift files ($MODE)…"
xcrun swiftc "${FLAGS[@]}" "${SOURCES[@]}" -o "$APP/Contents/MacOS/$APP_NAME"

# --- Bundle ------------------------------------------------------------------
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" >/dev/null

mkdir -p "$APP/Contents/Resources/fonts"
cp "$ROOT"/resources/fonts/*.otf "$APP/Contents/Resources/fonts/"

# Portuguese resources: without a pt-BR.lproj AppKit keeps the system menu
# items (About, Hide, Quit) in English.
if [[ -d "$ROOT/resources/pt-BR.lproj" ]]; then
  cp -R "$ROOT/resources/pt-BR.lproj" "$APP/Contents/Resources/"
fi

if [[ -f "$ROOT/resources/AppIcon.icns" ]]; then
  cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for the app to launch locally and to keep macOS from
# re-prompting about the (unsigned) bundle on every rebuild.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "→ Built $APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/^/  architectures: /' || true

if [[ "$RUN" == "1" ]]; then
  echo "→ Launching…"
  open "$APP"
fi

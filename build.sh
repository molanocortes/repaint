#!/bin/bash
# Builds Paint.app from source and (optionally) installs it.
#   ./build.sh            build into ./Paint.app
#   ./build.sh --install  build, then copy into /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Paint.app"
BUILD="$ROOT/build"
BIN="$BUILD/Paint"

# --- Preflight: a stale Command Line Tools file breaks every Swift build ----
STALE="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"
SIBLING="/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap"
if [ -f "$STALE" ] && [ -f "$SIBLING" ]; then
  cat >&2 <<'MSG'
------------------------------------------------------------------
Your Command Line Tools install has a leftover file from an older
version that makes EVERY Swift build fail with:

    error: redefinition of module 'SwiftBridging'

Both files declare the same module; module.modulemap is the stale
2023 leftover, bridging.modulemap is the current one. Remove the
stale copy (needs your password, one time only):

  sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap

Then run ./build.sh again.
------------------------------------------------------------------
MSG
  exit 1
fi

mkdir -p "$BUILD"

echo "Compiling..."
swiftc -O -target arm64-apple-macos13.0 \
  -o "$BIN" "$ROOT"/Sources/*.swift

if [ "${RUN_TESTS:-1}" = "1" ]; then
  echo "Running tests..."
  ENGINE_SRC="$ROOT/Sources/Bitmap.swift $ROOT/Sources/PaintState.swift $ROOT/Sources/CanvasView.swift"
  swiftc -o "$BUILD/EngineTest" $ENGINE_SRC "$ROOT/Tests/main.swift"
  "$BUILD/EngineTest" "$BUILD" | tail -1
  swiftc -o "$BUILD/UITest" $ENGINE_SRC "$ROOT/Sources/Chrome.swift" \
    "$ROOT/Sources/Ribbon.swift" "$ROOT/Sources/MainWindow.swift" "$ROOT/TestsUI/main.swift"
  "$BUILD/UITest" | tail -2
fi

echo "Building icon..."
python3 "$ROOT/make_icon.py" >/dev/null

echo "Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paint"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so Gatekeeper treats it as a normal locally-built app.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "(codesign skipped - the app still runs)"

echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/Paint.app"
  if [ ! -w /Applications ]; then DEST="$HOME/Applications/Paint.app"; mkdir -p "$HOME/Applications"; fi
  # Clear out the app's former name so only one copy is installed.
  rm -rf "$(dirname "$DEST")/ClassicPaint.app"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed: $DEST"
  echo "Open it once from Finder, then keep it in the Dock."
fi

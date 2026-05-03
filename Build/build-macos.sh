#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build the Radium GUI app on macOS.
#
# Defaults to arm64; export TARGET_CPU=x86_64 for Intel builds. Produces:
#   Bin/Radium                              — the bare executable
#   Bin/Radium.app/Contents/MacOS/Radium    — same binary, inside a proper
#   Bin/Radium.app/Contents/Info.plist        .app bundle so macOS treats
#                                             us as a real GUI app and Qt
#                                             attaches the native menu bar.
#
# Why both: lazbuild emits the bare executable; bundling is post-step.
# Running the bare binary directly will *not* show the menu bar on macOS.
# Use `open Bin/Radium.app` (or `make run`).
#
# Requires: Lazarus + Qt6Pas.framework installed
#   (brew install --cask lazarus, then build/install Qt6Pas separately).
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_CPU="${TARGET_CPU:-aarch64}"
PROJECT="$ROOT/Projects/Radium.lpi"
BIN="$ROOT/Bin"
APP="$BIN/Radium.app"

# Resolve lazbuild. PATH first (developer's choice), then the
# /Applications/lazarus install layout used by the official mac
# installer + brew cask.
LAZBUILD="${LAZBUILD:-}"
if [ -z "$LAZBUILD" ]; then
  for candidate in \
    "$(command -v lazbuild || true)" \
    "/Applications/lazarus/lazbuild" \
    "/Applications/Lazarus.app/Contents/Resources/lazbuild" \
    "/usr/local/bin/lazbuild"
  do
    if [ -x "$candidate" ]; then
      LAZBUILD="$candidate"
      break
    fi
  done
fi

if [ -z "$LAZBUILD" ]; then
  echo "lazbuild not found" >&2
  echo "  install Lazarus (brew install --cask lazarus, or fpcupdeluxe)" >&2
  echo "  or set LAZBUILD=/path/to/lazbuild" >&2
  exit 1
fi

if [ ! -f "$PROJECT" ]; then
  echo "Project not found: $PROJECT" >&2
  exit 1
fi

echo "[radium] lazbuild --ws=qt6 --cpu=$TARGET_CPU $PROJECT"
"$LAZBUILD" \
  --ws=qt6 \
  --os=darwin \
  --cpu="$TARGET_CPU" \
  --build-mode=Default \
  "$PROJECT"

echo "[radium] packaging .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Radium" "$APP/Contents/MacOS/Radium"

# Copy bundled assets (icon font, etc.) into the bundle's Resources
# directory so Radium.Gui.Icons can find them at runtime via the
# <bundle>/Contents/Resources/<...> lookup path. Optional — if the
# assets folder is missing the app still runs (just without icons).
if [ -d "$ROOT/Resources" ]; then
  cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
fi

# Minimum-viable Info.plist. Without LSMinimumSystemVersion +
# CFBundlePackageType=APPL the Qt6 macOS platform plugin will not
# install the native menu bar — the menu items end up in a TWindow
# attached to MainForm which Qt then hides because LCL declares the
# main form to be its own client area.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>Radium</string>
    <key>CFBundleIdentifier</key>            <string>dev.radium.gui</string>
    <key>CFBundleName</key>                  <string>Radium</string>
    <key>CFBundleDisplayName</key>           <string>Radium</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>CFBundleIconFile</key>              <string>Radium</string>
    <key>LSMinimumSystemVersion</key>        <string>11.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.finance</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
</dict>
</plist>
PLIST

# CFBundleIconFile resolves to <Contents/Resources/Radium.icns> — Finder
# expects it at the Resources root, not inside a subfolder. Copy it
# there alongside the staged Resources/Icons/ tree (which the lookup
# in Radium.Gui.Icons doesn't need but is harmless to keep).
if [ -f "$ROOT/Resources/Icons/Radium.icns" ]; then
  cp "$ROOT/Resources/Icons/Radium.icns" "$APP/Contents/Resources/Radium.icns"
fi

echo "[radium] built $APP"

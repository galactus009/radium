#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build the Radium GUI app on macOS.
# Defaults to arm64; export TARGET_CPU=x86_64 for Intel builds.
# Requires: lazarus + qt installed (brew install lazarus qt).
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-$(command -v lazbuild || true)}"
TARGET_CPU="${TARGET_CPU:-aarch64}"
PROJECT="$ROOT/Projects/Radium.lpi"

if [ -z "$LAZBUILD" ]; then
  echo "lazbuild not found in PATH" >&2
  echo "  brew install lazarus" >&2
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

echo "[radium] built $ROOT/Bin/Radium"

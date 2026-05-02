#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build the Radium GUI app on Linux.
# Defaults to x86_64; export TARGET_CPU=aarch64 for ARM Linux builds.
# Requires: lazarus + qt6-base-dev (apt) or equivalent.
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-$(command -v lazbuild || true)}"
TARGET_CPU="${TARGET_CPU:-x86_64}"
PROJECT="$ROOT/Projects/Radium.lpi"

if [ -z "$LAZBUILD" ]; then
  echo "lazbuild not found in PATH" >&2
  echo "  sudo apt install lazarus-ide qt6-base-dev" >&2
  exit 1
fi

if [ ! -f "$PROJECT" ]; then
  echo "Project not found: $PROJECT" >&2
  exit 1
fi

echo "[radium] lazbuild --ws=qt6 --cpu=$TARGET_CPU $PROJECT"
"$LAZBUILD" \
  --ws=qt6 \
  --os=linux \
  --cpu="$TARGET_CPU" \
  --build-mode=Default \
  "$PROJECT"

echo "[radium] built $ROOT/Bin/Radium"

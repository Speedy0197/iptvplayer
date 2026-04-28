#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"
MACOS_STAGE_DIR="$DIST_DIR/macos"
ANDROID_VERSION_CODE_MAX=2147483647

usage() {
  cat <<'EOF'
Usage: ./scripts/build-local-macos-dmg.sh <version> [build-number]

Example:
  ./scripts/build-local-macos-dmg.sh 1.0.33 133
  ./scripts/build-local-macos-dmg.sh 1.0.33

If build-number is omitted, a UTC timestamp is used (YYDDDHHMM),
which stays within Android's 32-bit versionCode limit.

This script only builds the macOS app and packages a DMG locally.
It does not commit, tag, push, or upload anything.

Requirements:
  - Run on macOS with Xcode and Flutter installed
  - create-dmg must be installed

Install create-dmg:
  brew install create-dmg
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be in semver format, for example 1.2.3" >&2
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(date -u +%y%j%H%M)"
  echo "No build number provided. Using auto-generated build number: $BUILD_NUMBER"
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must be numeric" >&2
  exit 1
fi

if (( BUILD_NUMBER > ANDROID_VERSION_CODE_MAX )); then
  echo "Build number must be <= $ANDROID_VERSION_CODE_MAX for Android versionCode compatibility" >&2
  exit 1
fi

require_cmd flutter
require_cmd create-dmg

mkdir -p "$MACOS_STAGE_DIR"
rm -rf "$MACOS_STAGE_DIR"/* "$DIST_DIR/streampilot-macos.dmg" "$DIST_DIR"/rw.*.streampilot-macos.dmg

cd "$APP_DIR"

echo "Fetching Flutter dependencies..."
flutter pub get

echo "Building macOS app..."
flutter build macos --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

APP_BUNDLE="$APP_DIR/build/macos/Build/Products/Release/StreamPilot.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "macOS app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

echo "Creating DMG..."
cp -R "$APP_BUNDLE" "$MACOS_STAGE_DIR/StreamPilot.app"
create-dmg \
  --volname "StreamPilot" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "StreamPilot.app" 150 185 \
  --hide-extension "StreamPilot.app" \
  --app-drop-link 450 185 \
  "$DIST_DIR/streampilot-macos.dmg" \
  "$MACOS_STAGE_DIR/"

cat <<EOF
Local macOS DMG created successfully.

Version: $VERSION
Build number: $BUILD_NUMBER
DMG: $DIST_DIR/streampilot-macos.dmg
EOF
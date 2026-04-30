#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"
MACOS_STAGE_DIR="$DIST_DIR/macos"
ANDROID_VERSION_CODE_MAX=2147483647

NOTARY_AUTH_ARGS=()

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

Optional macOS Developer ID signing + notarization:
  - MACOS_CODESIGN_IDENTITY (example: Developer ID Application: Your Name (TEAMID))
  - APPLE_NOTARYTOOL_PROFILE (recommended), or:
    - APPLE_ID
    - APPLE_TEAM_ID
    - APPLE_APP_PASSWORD

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

configure_notary_auth() {
  if [[ -n "${APPLE_NOTARYTOOL_PROFILE:-}" ]]; then
    NOTARY_AUTH_ARGS=(--keychain-profile "$APPLE_NOTARYTOOL_PROFILE")
    return 0
  fi

  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    NOTARY_AUTH_ARGS=(
      --apple-id "$APPLE_ID"
      --team-id "$APPLE_TEAM_ID"
      --password "$APPLE_APP_PASSWORD"
    )
    return 0
  fi

  return 1
}

notarize_file() {
  local file_path="$1"
  local label="$2"

  echo "Submitting $label for notarization..."
  xcrun notarytool submit "$file_path" "${NOTARY_AUTH_ARGS[@]}" --wait
}

sign_and_notarize_app() {
  local app_bundle="$1"

  echo "Signing macOS app bundle with Developer ID identity..."
  codesign --force --deep --options runtime --timestamp --sign "$MACOS_CODESIGN_IDENTITY" "$app_bundle"
  codesign --verify --deep --strict --verbose=2 "$app_bundle"

  local notary_tmp_dir
  local app_zip
  notary_tmp_dir="$(mktemp -d)"
  app_zip="$notary_tmp_dir/StreamPilot.app.zip"

  ditto -c -k --keepParent "$app_bundle" "$app_zip"
  notarize_file "$app_zip" "macOS app bundle"

  echo "Stapling notarization ticket to macOS app bundle..."
  xcrun stapler staple -v "$app_bundle"
  spctl --assess --type execute --verbose=4 "$app_bundle"

  rm -rf "$notary_tmp_dir"
}

sign_and_notarize_dmg() {
  local dmg_path="$1"

  echo "Signing DMG with Developer ID identity..."
  codesign --force --timestamp --sign "$MACOS_CODESIGN_IDENTITY" "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"

  notarize_file "$dmg_path" "macOS DMG"

  echo "Stapling notarization ticket to DMG..."
  xcrun stapler staple -v "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
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
require_cmd ditto

MACOS_SIGNING_ENABLED=false
if [[ -n "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
  MACOS_SIGNING_ENABLED=true
  require_cmd codesign
  require_cmd xcrun
  require_cmd spctl

  if ! configure_notary_auth; then
    echo "MACOS_CODESIGN_IDENTITY is set, but notarization credentials are missing." >&2
    echo "Set APPLE_NOTARYTOOL_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD." >&2
    exit 1
  fi

  echo "macOS signing/notarization enabled for local build."
else
  echo "macOS signing/notarization disabled (MACOS_CODESIGN_IDENTITY not set)."
fi

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

if [[ "$MACOS_SIGNING_ENABLED" == "true" ]]; then
  sign_and_notarize_app "$APP_BUNDLE"
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

if [[ "$MACOS_SIGNING_ENABLED" == "true" ]]; then
  sign_and_notarize_dmg "$DIST_DIR/streampilot-macos.dmg"
fi

cat <<EOF
Local macOS DMG created successfully.

Version: $VERSION
Build number: $BUILD_NUMBER
DMG: $DIST_DIR/streampilot-macos.dmg
EOF

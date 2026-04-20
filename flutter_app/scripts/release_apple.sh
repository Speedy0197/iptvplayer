#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd -- "$APP_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"
MACOS_STAGE_DIR="$DIST_DIR/macos"

usage() {
  cat <<'EOF'
Usage: ./scripts/release_apple.sh <version> [build-number]

Example:
  ./scripts/release_apple.sh 1.0.1 2
  ./scripts/release_apple.sh 1.0.1

If build-number is omitted, a UTC timestamp is used (YYYYMMDDHHMM).

Requirements:
  - Run on macOS with Xcode and Flutter installed
  - iOS signing must already be configured in Xcode
  - gh CLI must be installed and authenticated

Optional TestFlight upload (automatic if configured):
  - APPSTORE_API_KEY_ID
  - APPSTORE_API_ISSUER_ID
  - APPSTORE_API_PRIVATE_KEY or APPSTORE_API_PRIVATE_KEY_PATH
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

upload_to_testflight_if_configured() {
  if [[ -z "${APPSTORE_API_KEY_ID:-}" || -z "${APPSTORE_API_ISSUER_ID:-}" ]]; then
    echo "Skipping TestFlight upload (APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID not set)."
    return 0
  fi

  if [[ -z "${APPSTORE_API_PRIVATE_KEY:-}" && -z "${APPSTORE_API_PRIVATE_KEY_PATH:-}" ]]; then
    echo "Skipping TestFlight upload (set APPSTORE_API_PRIVATE_KEY or APPSTORE_API_PRIVATE_KEY_PATH)."
    return 0
  fi

  require_cmd xcrun

  local key_dir
  local key_file

  key_dir="$(mktemp -d)"
  key_file="$key_dir/AuthKey_${APPSTORE_API_KEY_ID}.p8"

  if [[ -n "${APPSTORE_API_PRIVATE_KEY_PATH:-}" ]]; then
    if [[ ! -f "$APPSTORE_API_PRIVATE_KEY_PATH" ]]; then
      echo "APPSTORE_API_PRIVATE_KEY_PATH does not exist: $APPSTORE_API_PRIVATE_KEY_PATH" >&2
      rm -rf "$key_dir"
      exit 1
    fi
    cp "$APPSTORE_API_PRIVATE_KEY_PATH" "$key_file"
  else
    printf '%s\n' "$APPSTORE_API_PRIVATE_KEY" > "$key_file"
  fi

  echo "Uploading IPA to TestFlight..."
  API_PRIVATE_KEYS_DIR="$key_dir" xcrun altool --upload-app --type ios --file "$DIST_DIR/iptv-player-ios.ipa" --apiKey "$APPSTORE_API_KEY_ID" --apiIssuer "$APPSTORE_API_ISSUER_ID"

  rm -rf "$key_dir"
  echo "TestFlight upload submitted. Processing continues in App Store Connect."
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
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be in semver format, for example 1.2.3" >&2
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
  echo "No build number provided. Using auto-generated build number: $BUILD_NUMBER"
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must be numeric" >&2
  exit 1
fi

require_cmd flutter
require_cmd git
require_cmd gh
require_cmd hdiutil
require_cmd ditto
require_cmd find

cd "$REPO_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has uncommitted changes. Commit or stash them before releasing." >&2
  exit 1
fi

if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "Working tree has untracked files. Clean them up before releasing." >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists locally." >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists on origin." >&2
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release $TAG already exists." >&2
  exit 1
fi

mkdir -p "$MACOS_STAGE_DIR"
rm -rf "$MACOS_STAGE_DIR"/* "$DIST_DIR/iptv-player-macos.dmg" "$DIST_DIR/iptv-player-ios.ipa"

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
ln -sf /Applications "$MACOS_STAGE_DIR/Applications"
hdiutil create -volname "StreamPilot" -srcfolder "$MACOS_STAGE_DIR" -ov -format UDZO "$DIST_DIR/iptv-player-macos.dmg" >/dev/null

echo "Building iOS IPA..."
flutter build ipa --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

IPA_SOURCE="$(find "$APP_DIR/build/ios/ipa" -maxdepth 1 -type f -name '*.ipa' | head -n 1)"
if [[ -z "$IPA_SOURCE" || ! -f "$IPA_SOURCE" ]]; then
  echo "iOS IPA not found in $APP_DIR/build/ios/ipa" >&2
  exit 1
fi

cp "$IPA_SOURCE" "$DIST_DIR/iptv-player-ios.ipa"

upload_to_testflight_if_configured

cd "$REPO_DIR"

echo "Creating and pushing tag $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Creating GitHub release if needed..."
gh release create "$TAG" --title "StreamPilot $TAG" --notes ""

echo "Uploading Apple assets..."
gh release upload "$TAG" \
  "$DIST_DIR/iptv-player-ios.ipa#iptv-player-ios.ipa" \
  "$DIST_DIR/iptv-player-macos.dmg#iptv-player-macos.dmg" \
  --clobber

cat <<EOF
Release assets uploaded successfully.

Tag: $TAG
iOS IPA: $DIST_DIR/iptv-player-ios.ipa
macOS DMG: $DIST_DIR/iptv-player-macos.dmg

Android APK and Windows installer will be attached by the GitHub Actions tag workflow.
EOF
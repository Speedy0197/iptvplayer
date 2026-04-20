#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd -- "$APP_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"
MACOS_STAGE_DIR="$DIST_DIR/macos"

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh <version> [build-number]

Example:
  ./scripts/release.sh 1.0.1 2
  ./scripts/release.sh 1.0.1

If build-number is omitted, a UTC timestamp is used (YYYYMMDDHHMM).

This script builds StreamPilot for all platforms:
  - macOS (DMG)
  - iOS (IPA)
  - Android TV (Universal APK)

Requirements:
  - Run on macOS with Xcode and Flutter installed
  - iOS signing must already be configured in Xcode
  - Android SDK configured (ANDROID_HOME set)
  - gh CLI must be installed and authenticated
  - Git working directory must be clean

Optional TestFlight upload (automatic if configured):
  - APPSTORE_API_KEY_ID
  - APPSTORE_API_ISSUER_ID
  - APPSTORE_API_PRIVATE_KEY or APPSTORE_API_PRIVATE_KEY_PATH

Optional release signing for Android:
  - ANDROID_KEYSTORE_PATH (defaults to debug key)
  - ANDROID_KEYSTORE_PASSWORD
  - ANDROID_KEYSTORE_KEY_ALIAS
  - ANDROID_KEYSTORE_KEY_PASSWORD
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
  API_PRIVATE_KEYS_DIR="$key_dir" xcrun altool --upload-app --type ios --file "$DIST_DIR/streampilot-ios.ipa" --apiKey "$APPSTORE_API_KEY_ID" --apiIssuer "$APPSTORE_API_ISSUER_ID"

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

# Check if release already exists (we'll update it if it does)
RELEASE_EXISTS=0
if gh release view "$TAG" >/dev/null 2>&1; then
  RELEASE_EXISTS=1
fi

# Clean dist directory
mkdir -p "$MACOS_STAGE_DIR"
rm -rf "$MACOS_STAGE_DIR"/* "$DIST_DIR"/*.dmg "$DIST_DIR"/*.ipa "$DIST_DIR"/*.apk

cd "$APP_DIR"

echo "Fetching Flutter dependencies..."
flutter pub get

# macOS Build
echo ""
echo "=== Building macOS app ==="
flutter build macos --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

APP_BUNDLE="$APP_DIR/build/macos/Build/Products/Release/StreamPilot.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "macOS app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

echo "Creating macOS DMG..."
cp -R "$APP_BUNDLE" "$MACOS_STAGE_DIR/StreamPilot.app"
ln -sf /Applications "$MACOS_STAGE_DIR/Applications"
hdiutil create -volname "StreamPilot" -srcfolder "$MACOS_STAGE_DIR" -ov -format UDZO "$DIST_DIR/streampilot-macos.dmg" >/dev/null

# iOS Build
echo ""
echo "=== Building iOS app ==="
flutter build ipa --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

IPA_SOURCE="$(find "$APP_DIR/build/ios/ipa" -maxdepth 1 -type f -name '*.ipa' | head -n 1)"
if [[ -z "$IPA_SOURCE" || ! -f "$IPA_SOURCE" ]]; then
  echo "iOS IPA not found in $APP_DIR/build/ios/ipa" >&2
  exit 1
fi

cp "$IPA_SOURCE" "$DIST_DIR/streampilot-ios.ipa"

# Android Build (Universal APK for Android TV)
echo ""
echo "=== Building Android TV app ==="

ANDROID_OUT_DIR="$APP_DIR/build/app/outputs/flutter-apk"

if [[ -n "${ANDROID_KEYSTORE_PATH:-}" ]]; then
  echo "Building Android with release signing..."
  if [[ ! -f "$ANDROID_KEYSTORE_PATH" ]]; then
    echo "Error: Keystore not found at $ANDROID_KEYSTORE_PATH" >&2
    exit 1
  fi
else
  echo "Note: Building Android with debug signing (use ANDROID_KEYSTORE_PATH for release signing)"
fi

flutter build apk \
  --release \
  --build-name="$VERSION" \
  --build-number="$BUILD_NUMBER" \
  2>&1 | grep -E "(Building|✓|Error|Warning:|└|├)" || true

if [[ ! -f "$ANDROID_OUT_DIR/app-release.apk" ]]; then
  echo "Android APK not found at $ANDROID_OUT_DIR/app-release.apk" >&2
  exit 1
fi

cp "$ANDROID_OUT_DIR/app-release.apk" "$DIST_DIR/streampilot-android.apk"

# TestFlight upload (optional)
echo ""
upload_to_testflight_if_configured

# Git tag and GitHub release
echo ""
echo "=== Creating GitHub release ==="
cd "$REPO_DIR"

echo "Creating and pushing tag $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Creating GitHub release..."

# Generate release notes with installation instructions
RELEASE_NOTES=$(cat <<'NOTES_EOF'
## Installation Guide

### iOS
Download and install via TestFlight or App Store.

### macOS
1. Download `StreamPilot-macOS.dmg`
2. Open the DMG file
3. Drag StreamPilot to Applications folder
4. Launch from Applications

### Android TV
**Easy Method (Recommended):**
1. Download `StreamPilot-AndroidTV.apk`
2. Copy to USB drive or cloud storage
3. On TV, open file manager app
4. Tap the APK file to install
5. Confirm installation
6. Find StreamPilot in TV apps menu

**Advanced Method (ADB):**
```bash
adb connect TV_IP_ADDRESS:5555
adb install -r StreamPilot-AndroidTV.apk
```

## Features
- Stream IPTV channels from M3U playlists
- Create custom groups and favorites
- EPG support
- Secure authentication

## Requirements
- Network connection to backend server
- For Android TV: Unknown sources enabled (in Settings → Security)

## Support
For issues or questions, please check the documentation or open an issue on GitHub.
NOTES_EOF
)

if [[ $RELEASE_EXISTS -eq 1 ]]; then
  echo "Release already exists. Updating with new notes and assets..."
  gh release edit "$TAG" --notes "$RELEASE_NOTES"
else
  echo "Creating new release..."
  gh release create "$TAG" --title "StreamPilot $TAG" --notes "$RELEASE_NOTES"
fi

echo "Uploading release assets..."
gh release upload "$TAG" \
  "$DIST_DIR/streampilot-ios.ipa#StreamPilot-iOS.ipa" \
  "$DIST_DIR/streampilot-macos.dmg#StreamPilot-macOS.dmg" \
  "$DIST_DIR/streampilot-android.apk#StreamPilot-AndroidTV.apk" \
  --clobber

cat <<EOF

════════════════════════════════════════════════════════════════
  Release Complete: StreamPilot $TAG
════════════════════════════════════════════════════════════════

Git Tag: $TAG
GitHub Release: https://github.com/flo/IptvPlayer/releases/tag/$TAG

Distribution:
  • iOS:       streampilot-ios.ipa (TestFlight or App Store)
  • macOS:     streampilot-macos.dmg
  • Android TV: streampilot-android.apk (Universal, sideload via file manager or ADB)

Android TV Installation:
  Option 1 (Easy): Download APK → USB drive → TV file manager → tap to install
  Option 2 (ADB):  adb connect TV_IP:5555 && adb install -r streampilot-android.apk

To customize backend URL, users can edit in the app login screen (debug mode).
EOF

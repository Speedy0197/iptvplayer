#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd -- "$APP_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/dist"
MACOS_STAGE_DIR="$DIST_DIR/macos"
VERSION_FILE="$REPO_DIR/docs/version.json"

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh <version> [build-number]

Example:
  ./scripts/release.sh 1.0.1 2
  ./scripts/release.sh 1.0.1

If build-number is omitted, a UTC timestamp is used (YYDDDHHMM),
which stays within Android's 32-bit versionCode limit.

Requirements:
  - Run on macOS with Xcode and Flutter installed
  - iOS signing must already be configured in Xcode
  - gh CLI must be installed and authenticated

Optional TestFlight upload (automatic if configured):
  - APPSTORE_API_KEY_ID
  - APPSTORE_API_ISSUER_ID
  - APPSTORE_API_PRIVATE_KEY or APPSTORE_API_PRIVATE_KEY_PATH

Install create-dmg for the macOS DMG:
  brew install create-dmg
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

update_pages_version_file() {
  # Preserve the existing ios_available_version so iOS users are not force-updated
  # until TestFlight has approved the build. Run --mark-ios <version> for that.
  local current_ios_version
  current_ios_version="$(python3 -c "import json,sys; d=json.load(open('$VERSION_FILE')); print(d.get('ios_available_version', d.get('latest_version','')))" 2>/dev/null || echo "")"
  if [[ -z "$current_ios_version" ]]; then
    current_ios_version="$VERSION"
  fi
  cat > "$VERSION_FILE" <<EOF
{
  "latest_version": "$VERSION",
  "ios_available_version": "$current_ios_version"
}
EOF
}

mark_ios_available() {
  local mark_version="$1"
  if [[ ! "$mark_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must be in semver format, for example 1.2.3" >&2
    exit 1
  fi

  cd "$REPO_DIR"

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit or stash them before marking iOS." >&2
    exit 1
  fi

  local current_latest
  current_latest="$(python3 -c "import json,sys; d=json.load(open('$VERSION_FILE')); print(d.get('latest_version',''))" 2>/dev/null || echo "")"
  if [[ -z "$current_latest" ]]; then
    current_latest="$mark_version"
  fi

  cat > "$VERSION_FILE" <<EOF
{
  "latest_version": "$current_latest",
  "ios_available_version": "$mark_version"
}
EOF

  git add "$VERSION_FILE"
  git commit -m "chore: mark ios available v$mark_version"
  git push origin HEAD
  echo "iOS users will now be prompted to update to $mark_version."
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ ${1:-} == "--mark-ios" ]]; then
  if [[ $# -ne 2 ]]; then
    echo "Usage: ./scripts/release.sh --mark-ios <version>" >&2
    exit 1
  fi
  mark_ios_available "$2"
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="${2:-}"
TAG="v$VERSION"
ANDROID_VERSION_CODE_MAX=2147483647

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be in semver format, for example 1.2.3" >&2
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  # Use 9-digit UTC timestamp (YYDDDHHMM) to keep Android versionCode int-safe.
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
require_cmd git
require_cmd gh
require_cmd create-dmg
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
rm -rf "$MACOS_STAGE_DIR"/* "$DIST_DIR/streampilot-macos.dmg" "$DIST_DIR/streampilot-ios.ipa"

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

echo "Building iOS IPA..."
flutter build ipa --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

IPA_SOURCE="$(find "$APP_DIR/build/ios/ipa" -maxdepth 1 -type f -name '*.ipa' | head -n 1)"
if [[ -z "$IPA_SOURCE" || ! -f "$IPA_SOURCE" ]]; then
  echo "iOS IPA not found in $APP_DIR/build/ios/ipa" >&2
  exit 1
fi

cp "$IPA_SOURCE" "$DIST_DIR/streampilot-ios.ipa"

upload_to_testflight_if_configured

cd "$REPO_DIR"

update_pages_version_file

# Update pubspec.yaml version to match the release
sed -i '' "s/^version: .*/version: $VERSION+$BUILD_NUMBER/" "$APP_DIR/pubspec.yaml"

if ! git diff --quiet -- "$VERSION_FILE" "$APP_DIR/pubspec.yaml"; then
  git add "$VERSION_FILE" "$APP_DIR/pubspec.yaml"
  git commit -m "chore: release $TAG"
  git push origin HEAD
fi

echo "Creating and pushing tag $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Creating GitHub release if needed..."
gh release create "$TAG" --title "StreamPilot $TAG" --notes ""

echo "Uploading Apple assets..."
gh release upload "$TAG" \
  "$DIST_DIR/streampilot-ios.ipa#streampilot-ios.ipa" \
  "$DIST_DIR/streampilot-macos.dmg#streampilot-macos.dmg" \
  --clobber

cat <<EOF
Release assets uploaded successfully.

Tag: $TAG
iOS IPA: $DIST_DIR/streampilot-ios.ipa
macOS DMG: $DIST_DIR/streampilot-macos.dmg

Android APK and Windows installer will be attached by the GitHub Actions tag workflow.

IMPORTANT: iOS users will NOT be force-updated yet.
Once TestFlight has approved the build, run:
  ./scripts/release.sh --mark-ios $VERSION
EOF
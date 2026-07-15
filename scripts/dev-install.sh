#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"
PROJECT="$ROOT/StudioRecorder.xcodeproj"
SCHEME="StudioRecorder"
DEV_NAME="Studio Recorder DEV"
DEV_BUNDLE_ID="ua.com.rmarinsky.studiorecorder.dev"
BUILD_DIR="$ROOT/build/dev"
DESTINATION="/Applications/$DEV_NAME.app"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

cd "$ROOT"
xcodegen generate --spec project.yml --project "$ROOT"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  "PRODUCT_NAME=$DEV_NAME" \
  "PRODUCT_BUNDLE_IDENTIFIER=$DEV_BUNDLE_ID" \
  build

BUILT_APP="$BUILD_DIR/Build/Products/Debug/$DEV_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Expected build product was not created: $BUILT_APP" >&2
  exit 1
fi

if pgrep -x "$DEV_NAME" >/dev/null 2>&1; then
  osascript -e "tell application \"$DEV_NAME\" to quit" || true
  sleep 1
fi

TMPDIR_VALUE="${TMPDIR:-/tmp}"
STAGING_DIR="$(mktemp -d "$TMPDIR_VALUE/studio-recorder-dev.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$BUILT_APP" "$STAGING_DIR/$DEV_NAME.app"

rm -rf "$DESTINATION"
mv "$STAGING_DIR/$DEV_NAME.app" "$DESTINATION"
open "$DESTINATION"

echo "Installed and launched: $DESTINATION"
echo "Grant Screen Recording, Microphone, and Camera access for $DEV_NAME on first launch."

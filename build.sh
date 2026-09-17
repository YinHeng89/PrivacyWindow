#!/usr/bin/env bash
#
# Builds PrivacyWindow.app from the SwiftPM package.
#
#   ./build.sh            build and sign
#   ./build.sh --run      build, sign, and launch the app
#   ./build.sh --universal  build for Apple Silicon and Intel
#
# Uses ad-hoc signing by default. macOS asks for Screen Recording permission
# again after every rebuild. Set SIGN_IDENTITY to use your own identity.

set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="PrivacyWindow"
BUNDLE="build/${APP_NAME}.app"

BUILD_ARGS=(-c release)
RUN_APP=false
for argument in "$@"; do
  case "$argument" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    --run) RUN_APP=true ;;
    *) echo "Unknown argument: $argument" >&2; exit 1 ;;
  esac
done

swift build "${BUILD_ARGS[@]}" --product PrivacyWindow

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_PATH/PrivacyWindow"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/PrivacyWindow"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

TIMESTAMP=--timestamp
if [[ "$SIGN_IDENTITY" == - ]]; then
  TIMESTAMP=--timestamp=none
fi
codesign --force --options runtime "$TIMESTAMP" \
  --sign "$SIGN_IDENTITY" "$BUNDLE"
codesign --verify --strict --verbose=1 "$BUNDLE"

echo "built ${BUNDLE}"

if "$RUN_APP"; then
  pkill -x PrivacyWindow 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  echo "launched"
fi

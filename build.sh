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

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# A local `.sign-identity` file (git-ignored) holds the cert name so it does
# not have to be exported for every build.
if [[ -z "$SIGN_IDENTITY" && -f .sign-identity ]]; then
  SIGN_IDENTITY="$(cat .sign-identity)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

# Ad-hoc signing (-) has no stable identity, so macOS keys the Screen Recording
# permission to a code signature that changes on every build — that is why the
# "Screen Recording" prompt comes back after each rebuild and the old grant has
# to be deleted first. A Developer ID certificate gives a stable Team ID and the
# permission sticks. Set SIGN_IDENTITY (or .sign-identity) to e.g.
#   "Developer ID Application: Your Name (TEAMID)"
if [[ "$SIGN_IDENTITY" == - ]]; then
  echo "⚠️  Ad-hoc signing: macOS will re-ask for Screen Recording after every build." >&2
  echo "   Sign with a Developer ID to make the permission stick — set SIGN_IDENTITY" >&2
  echo "   to your 'Developer ID Application: …' certificate (or write it to .sign-identity)." >&2
fi
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
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

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

#!/usr/bin/env bash
#
# Writes the version being released into Resources/Info.plist before the bundle
# is assembled.
#
#   Scripts/stamp-version.sh 0.2.0 42
#
# The repository keeps placeholder values (0.1.0 / 1) on purpose. A version that
# lives twice — once in a git tag and once in a checked-in file — is a version
# that eventually disagrees with itself, and the one inside the bundle is the
# one the update channel compares. So the tag is the only source and this runs
# in CI, where the working copy is disposable.

set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "usage: $(basename "$0") <short-version> <build-number>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
PLIST="Resources/Info.plist"

if [[ ! -f "$PLIST" ]]; then
  echo "no such file: $PLIST" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

echo "stamped $PLIST: $VERSION ($BUILD)"

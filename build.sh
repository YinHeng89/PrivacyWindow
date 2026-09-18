#!/usr/bin/env bash
#
# Builds PrivacyWindow.app from the SwiftPM package.
#
#   ./build.sh                        build and sign (asks about the version first)
#   ./build.sh --run                  build, sign, and launch the app
#   ./build.sh --universal            build for Apple Silicon and Intel
#   ./build.sh --version X.Y.Z        set the version explicitly, no prompt
#   ./build.sh --bump [patch|minor|major]   bump instead of prompting (patch by default)
#   ./build.sh --keep-version         build with whatever version is in Info.plist
#
# The version lives in Resources/Info.plist. CFBundleShortVersionString is what
# the About screen shows; CFBundleVersion is the build number and only grows.
# Both are bumped on every local build, so each .app you copy into /Applications
# carries a version you can trace back to it.
#
# The release workflow overrides this again with Scripts/stamp-version.sh, where
# the git tag is the source of truth. A local build is the one place a version is
# allowed to exist without a tag to justify it.

set -euo pipefail
cd "$(dirname "$0")"

PLIST="Resources/Info.plist"

if [[ ! -f "$PLIST" ]]; then
  echo "missing $PLIST" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
BUILD_ARGS=(-c release)
RUN_APP=false
VERSION_MODE="ask"        # ask | set | bump | keep
REQUESTED_VERSION=""
REQUESTED_PART="patch"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64); shift ;;
    --run) RUN_APP=true; shift ;;
    --keep-version) VERSION_MODE="keep"; shift ;;
    --version)
      VERSION_MODE="set"
      REQUESTED_VERSION="${2:-}"
      if [[ -z "$REQUESTED_VERSION" ]]; then
        echo "--version needs a version number, e.g. --version 1.2.0" >&2
        exit 1
      fi
      shift 2
      ;;
    --bump)
      VERSION_MODE="bump"
      if [[ $# -gt 1 && "$2" != -* ]]; then
        REQUESTED_PART="$2"
        shift 2
      else
        REQUESTED_PART="patch"
        shift
      fi
      if [[ "$REQUESTED_PART" != patch && "$REQUESTED_PART" != minor && "$REQUESTED_PART" != major ]]; then
        echo "--bump takes patch, minor or major (got '$REQUESTED_PART')" >&2
        exit 1
      fi
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Reading and writing Info.plist
#
# PlistBuddy can read it, but writing with it rewrites the whole file and drops
# every XML comment — the explanatory ones above LSMultipleInstancesProhibited
# and NSScreenCaptureUsageDescription included. So writing is a line-level
# substitution that leaves everything else byte-identical.
# ---------------------------------------------------------------------------
plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

plist_set() {
  local key="$1" value="$2" tmp="$PLIST.pwtmp"
  if ! awk -v key="$key" -v value="$value" '
      BEGIN { hits = 0 }
      {
        line = $0
        if (previous ~ ("<key>" key "</key>") && line ~ /<string>[^<]*<\/string>/) {
          sub(/>[^<]*</, ">" value "<", line)
          hits++
        }
        print line
        previous = $0
      }
      END { if (hits != 1) exit 1 }
    ' "$PLIST" > "$tmp"; then
    rm -f "$tmp"
    echo "could not update $key in $PLIST — is it still a plain plist?" >&2
    exit 1
  fi
  mv "$tmp" "$PLIST"
}

# Three dot-separated numbers. Anything looser ends up being compared
# lexicographically somewhere and "0.10.0" loses to "0.9.0".
is_valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]
}

# "1.2" is fine to type and awkward to compare, so it is stored as "1.2.0".
normalize_version() {
  local version="$1"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    printf '%s.0' "$version"
  else
    printf '%s' "$version"
  fi
}

# Everything up to the first hyphen: "1.2.0-rc.1" bumps as "1.2.0".
bump_version() {
  local version="${1%%-*}" part="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$version"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ -z "${minor:-}" || "$minor" =~ ^[0-9]+$ ]] || return 1
  [[ -z "${patch:-}" || "$patch" =~ ^[0-9]+$ ]] || return 1
  case "$part" in
    major) printf '%d.0.0' "$((10#${major:-0} + 1))" ;;
    minor) printf '%d.%d.0' "$((10#${major:-0}))" "$((10#${minor:-0} + 1))" ;;
    patch) printf '%d.%d.%d' "$((10#${major:-0}))" "$((10#${minor:-0}))" "$((10#${patch:-0} + 1))" ;;
  esac
}

CURRENT_VERSION="$(plist_get CFBundleShortVersionString)"
CURRENT_BUILD="$(plist_get CFBundleVersion)"
[[ "$CURRENT_VERSION" =~ ^[0-9]+$ ]] && CURRENT_VERSION="$CURRENT_VERSION.0"
if [[ -z "$CURRENT_VERSION" ]]; then
  CURRENT_VERSION="0.1.0"
fi
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  CURRENT_BUILD=0
fi

if ! is_valid_version "$CURRENT_VERSION"; then
  echo "$PLIST has version '$CURRENT_VERSION', which is not X.Y.Z." >&2
  echo "Nothing to bump automatically — set it with --version." >&2
  exit 1
fi

NEXT_PATCH="$(bump_version "$CURRENT_VERSION" patch || true)"
if [[ -z "$NEXT_PATCH" ]]; then
  echo "could not work out the next version from '$CURRENT_VERSION'" >&2
  exit 1
fi
NEXT_BUILD=$((10#${CURRENT_BUILD} + 1))

# ---------------------------------------------------------------------------
# Choosing the version. Piped or scripted runs have no one to ask, so they take
# the bump; anything else stops and shows what is about to happen first.
# ---------------------------------------------------------------------------
NEW_VERSION=""
NEW_BUILD="$NEXT_BUILD"

if [[ "$VERSION_MODE" == keep ]]; then
  NEW_VERSION="$CURRENT_VERSION"
  NEW_BUILD="$CURRENT_BUILD"
elif [[ "$VERSION_MODE" == set ]]; then
  if ! is_valid_version "$REQUESTED_VERSION"; then
    echo "'$REQUESTED_VERSION' is not a valid version — expected X.Y or X.Y.Z" >&2
    exit 1
  fi
  NEW_VERSION="$(normalize_version "$REQUESTED_VERSION")"
elif [[ "$VERSION_MODE" == bump ]]; then
  NEW_VERSION="$(bump_version "$CURRENT_VERSION" "$REQUESTED_PART")"
  if [[ -z "$NEW_VERSION" ]]; then
    echo "could not bump $CURRENT_VERSION" >&2
    exit 1
  fi
elif [[ ! -t 0 ]]; then
  NEW_VERSION="$NEXT_PATCH"
  echo "(no terminal to ask in; taking the automatic bump — see --keep-version)" >&2
else
  echo ""
  echo "PrivacyWindow — 构建前确认版本号"
  echo ""
  echo "  当前版本  $CURRENT_VERSION (build $CURRENT_BUILD)"
  echo "  自增版本  $NEXT_PATCH (build $NEXT_BUILD)"
  echo ""
  echo "  回车        自增到 $NEXT_PATCH"
  echo "  版本号      手动指定，如 1.2.0"
  echo "  patch/minor/major   指定自增哪一段"
  echo "  k           保持 $CURRENT_VERSION 不变"
  echo "  q           不构建，退出"
  echo ""
  while true; do
    printf '  请选择 > '
    if ! read -r answer; then answer="q"; fi
    answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
    case "$answer" in
      "") NEW_VERSION="$NEXT_PATCH"; break ;;
      major|minor|patch)
        NEW_VERSION="$(bump_version "$CURRENT_VERSION" "$answer" || true)"
        if [[ -n "$NEW_VERSION" ]]; then break; fi
        echo "  无法从 $CURRENT_VERSION 自增"
        ;;
      k|keep) NEW_VERSION="$CURRENT_VERSION"; NEW_BUILD="$CURRENT_BUILD"; break ;;
      q|quit)
        echo "已取消，未构建"
        exit 0
        ;;
      *)
        if is_valid_version "$answer"; then
          NEW_VERSION="$(normalize_version "$answer")"
          break
        fi
        echo "  '$answer' 不是版本号，也不是 patch/minor/major、k、q，请重试"
        ;;
    esac
  done
  echo ""
fi

plist_set CFBundleShortVersionString "$NEW_VERSION"
plist_set CFBundleVersion "$NEW_BUILD"

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" && "$NEW_BUILD" == "$CURRENT_BUILD" ]]; then
  echo "版本号 $NEW_VERSION (build $NEW_BUILD)，未变动"
else
  echo "版本号 $CURRENT_VERSION (build $CURRENT_BUILD) → $NEW_VERSION (build $NEW_BUILD)"
fi

# ---------------------------------------------------------------------------
# Signing identity
# ---------------------------------------------------------------------------
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

# SwiftPM touches ~/.swiftpm/security, which is denied when the build itself
# runs inside a macOS sandbox ("sandbox_apply: Operation not permitted").
# Retry once with --disable-sandbox instead of failing outright.
swift_build() {
  local output
  if output="$(swift build "$@" 2>&1)"; then
    [[ -n "$output" ]] && printf '%s\n' "$output"
    return 0
  fi
  if printf '%s' "$output" | grep -q "sandbox_apply"; then
    echo "⚠️  swift build is sandboxed here; retrying with --disable-sandbox." >&2
    swift build "$@" --disable-sandbox
    return $?
  fi
  printf '%s\n' "$output"
  return 1
}

swift_build "${BUILD_ARGS[@]}" --product PrivacyWindow

BIN_PATH="$(swift_build "${BUILD_ARGS[@]}" --show-bin-path)"
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

echo "built ${BUNDLE} — version ${NEW_VERSION} (build ${NEW_BUILD})"

if "$RUN_APP"; then
  pkill -x PrivacyWindow 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  echo "launched"
fi

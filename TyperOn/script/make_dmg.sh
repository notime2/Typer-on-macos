#!/usr/bin/env bash
set -euo pipefail

# Builds a Release .app and packages it into a distributable .dmg.
#
# The build uses ad-hoc signing (CODE_SIGN_IDENTITY "-"), so the result is NOT
# notarized. macOS will quarantine it on download and users must clear the
# quarantine attribute manually. See the Installation section of README.md.

APP_NAME="Typer On"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/TyperOn.xcodeproj"
SCHEME="TyperOn"
DERIVED_DATA_PATH="/tmp/TyperOnRelease"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
OUT_DIR="$ROOT_DIR/build"
STAGE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

build_app() {
  cd "$ROOT_DIR"
  command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
  }
  xcodegen generate
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

resolve_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_BUNDLE/Contents/Info.plist"
}

make_dmg() {
  local version="$1"
  local dmg_path="$OUT_DIR/TyperOn-$version.dmg"

  # Copy the whole bundle. Copying only Contents/MacOS produces an app with a
  # generic icon and no resources.
  cp -R "$APP_BUNDLE" "$STAGE_DIR/"
  cp "$ROOT_DIR/../LICENSE" "$STAGE_DIR/LICENSE.txt"
  cp "$ROOT_DIR/../NOTICE" "$STAGE_DIR/NOTICE.txt"
  ln -s /Applications "$STAGE_DIR/Applications"

  mkdir -p "$OUT_DIR"
  rm -f "$dmg_path"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$dmg_path"

  echo
  echo "Created $dmg_path"
  echo
  echo "This DMG is ad-hoc signed and NOT notarized. On another Mac, macOS will"
  echo "refuse to open it until the user runs:"
  echo "  xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
}

build_app
VERSION="$(resolve_version)"
make_dmg "$VERSION"

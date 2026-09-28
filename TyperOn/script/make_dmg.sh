#!/usr/bin/env bash
set -euo pipefail

# Builds a Release .app and packages it into a distributable .dmg.
#
# Signing: with TYPERON_CODESIGN_IDENTITY set (and optionally
# TYPERON_CODESIGN_KEYCHAIN), the app and the embedded Sparkle code are re-signed
# with that identity. A stable identity keeps the designated requirement, and so
# the user's Accessibility grant and Sparkle's update check, the same across
# releases. Without it the build stays ad-hoc signed, and every new build looks
# like a different app to macOS.
#
# Either way the result is NOT notarized. macOS quarantines a downloaded DMG and
# users must clear the quarantine attribute manually. See README.md.

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

# Signs the staged copy, never the DerivedData product, so a later unsigned run
# cannot package a stale signature left behind by an earlier signed one.
sign_app() {
  local app="$1"
  [[ -n "${TYPERON_CODESIGN_IDENTITY:-}" ]] || {
    echo "TYPERON_CODESIGN_IDENTITY is not set; keeping the ad-hoc signature."
    return
  }
  local sign=(codesign --force --options runtime --timestamp=none --sign "$TYPERON_CODESIGN_IDENTITY")
  if [[ -n "${TYPERON_CODESIGN_KEYCHAIN:-}" ]]; then
    sign+=(--keychain "$TYPERON_CODESIGN_KEYCHAIN")
  fi
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"

  # Inside out: Sparkle's helpers, the framework, then the app itself.
  local code
  for code in "$sparkle"/Versions/B/XPCServices/*.xpc "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    "${sign[@]}" --preserve-metadata=entitlements "$code"
  done
  "${sign[@]}" --entitlements "$ROOT_DIR/Resources/TyperOn.entitlements" "$app"

  codesign --verify --deep --strict "$app"
  codesign --display --requirements - "$app"
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
  sign_app "$STAGE_DIR/$APP_NAME.app"
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
  echo "This DMG is NOT notarized. On another Mac, macOS will"
  echo "refuse to open it until the user runs:"
  echo "  xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
}

build_app
VERSION="$(resolve_version)"
make_dmg "$VERSION"

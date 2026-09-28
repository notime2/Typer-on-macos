#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Typer On"
BUNDLE_ID="com.typeron.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/TyperOn.xcodeproj"
SCHEME="TyperOn"
DERIVED_DATA_PATH="/tmp/TyperOnRun"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

kill_existing_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  cd "$ROOT_DIR"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

kill_existing_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

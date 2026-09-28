#!/bin/bash
# Build an isolated optimized adapter, then emit metadata-only JSONL.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_ROOT=""
VARIANT="candidate"
REVISION=""
MODE="build-and-run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE_ROOT="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --build-only) [[ "$MODE" == "build-and-run" ]] || { echo "Choose one execution mode" >&2; exit 64; }; MODE="build-only"; shift ;;
    --run-only) [[ "$MODE" == "build-and-run" ]] || { echo "Choose one execution mode" >&2; exit 64; }; MODE="run-only"; shift ;;
    *) echo "usage: $0 [--source-root repo] [--output-root directory] [--variant label] [--revision commit] [--build-only | --run-only]" >&2; exit 64 ;;
  esac
done
if [[ "$MODE" == "run-only" && -z "$OUTPUT_ROOT" ]]; then
  echo "--run-only requires --output-root from a previous build" >&2
  exit 64
fi
[[ -n "$OUTPUT_ROOT" ]] || OUTPUT_ROOT="$(mktemp -d /tmp/typer-dialog-probe.XXXXXX)"
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
[[ -n "$REVISION" ]] || REVISION="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
BUNDLE="$OUTPUT_ROOT/Dialog Layout Probe.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/Dialog Layout Probe"
if [[ "$MODE" != "run-only" ]]; then
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.typeron.dialog-layout-probe</string>
<key>CFBundleExecutable</key><string>Dialog Layout Probe</string>
<key>CFBundleName</key><string>Dialog Layout Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
SOURCES=()
while IFS= read -r -d '' SOURCE; do
  SOURCES+=("$SOURCE")
done < <(rg --files -0 "$SOURCE_ROOT/TyperOn/Sources" -g '*.swift' -g '!TyperOnApp.swift')
[[ ${#SOURCES[@]} -gt 0 ]] || { echo "No app sources found" >&2; exit 66; }
echo "Building optimized diagnostic adapter from $SOURCE_ROOT ($REVISION)" >&2
xcrun swiftc -O -swift-version 6 -parse-as-library -module-name Typer_On \
  -target "$(uname -m)-apple-macos26.0" \
  "${SOURCES[@]}" "$SCRIPT_DIR/dialog_layout_probe.swift" \
  -o "$EXECUTABLE" > "$OUTPUT_ROOT/build.log" 2>&1
codesign --force --sign - "$BUNDLE" > "$OUTPUT_ROOT/signing.log" 2>&1
printf '%s\n' "$REVISION" > "$OUTPUT_ROOT/revision.txt"
printf '%s\n' "$VARIANT" > "$OUTPUT_ROOT/variant.txt"
fi
if [[ "$MODE" == "build-only" ]]; then
  echo "$BUNDLE"
  exit 0
fi
[[ -x "$EXECUTABLE" && -f "$OUTPUT_ROOT/revision.txt" && -f "$OUTPUT_ROOT/variant.txt" ]] || {
  echo "Missing previously built probe or its metadata: $OUTPUT_ROOT" >&2
  exit 66
}
# Always identify the compiled artifact, even if a run-only caller passes source flags.
REVISION="$(cat "$OUTPUT_ROOT/revision.txt")"
VARIANT="$(cat "$OUTPUT_ROOT/variant.txt")"
PROBE_SHA="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
echo "Running ~30 second synthetic probe; output: $OUTPUT_ROOT/results.jsonl" >&2
DIALOG_PROBE_REVISION="$REVISION" DIALOG_PROBE_VARIANT="$VARIANT" DIALOG_PROBE_SHA256="$PROBE_SHA" \
  "$EXECUTABLE" > "$OUTPUT_ROOT/results.jsonl" 2> "$OUTPUT_ROOT/runtime.log"
echo "$OUTPUT_ROOT/results.jsonl"

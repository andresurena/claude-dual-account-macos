#!/bin/zsh
#
# Builds a double-clickable macOS .app that opens Terminal, cd's into a
# project folder, and launches your wrapper command (e.g. `claude-work`).
#
# Why an AppleScript-compiled app and not a plain shell script wrapped in
# a .app bundle: a raw shell script as CFBundleExecutable isn't a native
# Mach-O binary, and macOS's LaunchServices can misidentify the app's
# architecture from it — on Apple Silicon this can surface a spurious
# "requires Rosetta / Intel app" notification. `osacompile` produces a
# real universal (arm64 + x86_64) binary, which avoids that entirely.
#
# Usage:
#   ./build-cli-launcher.sh "App Name" "wrapper-command" [project-dir] [icon.icns]
#
# Example:
#   ./build-cli-launcher.sh "Claude Work Code" "claude-work" \
#       "$HOME/Developer/work-projects" "$HOME/my-icon.icns"

set -euo pipefail

APP_NAME="${1:?App display name required, e.g. \"Claude Work Code\"}"
WRAPPER_CMD="${2:?Wrapper command required, e.g. claude-work}"
PROJECT_DIR="${3:-}"
ICON_PATH="${4:-}"

APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.$(whoami | tr -dc 'a-z0-9').$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ -n "$PROJECT_DIR" ]; then
  SCRIPT_LINE="cd \\\"${PROJECT_DIR}\\\" && exec ~/bin/${WRAPPER_CMD}"
else
  SCRIPT_LINE="exec ~/bin/${WRAPPER_CMD}"
fi

cat > "$WORKDIR/launcher.applescript" <<EOF
tell application "Terminal"
    activate
    do script "${SCRIPT_LINE}"
end tell
EOF

echo "== Compiling $APP_NAME =="
rm -rf "$APP_PATH"
osacompile -o "$APP_PATH" "$WORKDIR/launcher.applescript"

/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_PATH/Contents/Info.plist"

echo "== Signing (ad-hoc) =="
codesign --force --deep -s - "$APP_PATH"

if [ -n "$ICON_PATH" ]; then
  if ! command -v fileicon >/dev/null 2>&1; then
    echo "fileicon not found — installing via Homebrew"
    brew install fileicon
  fi
  echo "== Applying icon =="
  fileicon set "$APP_PATH" "$ICON_PATH"
fi

codesign -v "$APP_PATH" && echo "OK: $APP_PATH is valid and ready to launch"

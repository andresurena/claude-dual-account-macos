#!/bin/zsh
#
# Builds a double-clickable "Update <App Name>.app" that re-runs
# build-desktop-concurrent.sh with the same parameters you originally
# used — for whenever Claude Desktop updates and your concurrent
# duplicate (see docs/desktop-concurrent-instances.md) needs refreshing
# to match.
#
# Usage:
#   ./build-update-helper.sh "App Name" /path/to/core-install-dir /path/to/profile-data-dir /path/to/claude-config-dir [browser-app-name] [icon.icns]
#
# Example (matching the earlier build-desktop-concurrent.sh example):
#   ./build-update-helper.sh "Claude Work Desktop" \
#       "$HOME/.claude-work/core" "$HOME/.claude-work/desktop-profile" \
#       "$HOME/.claude-work" "Microsoft Edge" "$HOME/my-icon.icns"
#
# This creates "Update Claude Work Desktop.app" in /Applications. Double
# click it any time Claude Desktop updates; it opens Terminal, re-runs
# the duplication with the same parameters, and tells you when it's done.
#
# Quit the running duplicate before using it — the rebuild will fail (or
# corrupt files) if the old copy still has files open.

set -euo pipefail

APP_NAME="${1:?App display name required, e.g. \"Claude Work Desktop\"}"
CORE_INSTALL_DIR="${2:?Directory holding the duplicated core app required, e.g. ~/.claude-work/core}"
PROFILE_DIR="${3:?Profile data directory required, e.g. ~/.claude-work/desktop-profile}"
CLAUDE_CONFIG_DIR_VALUE="${4:?CLAUDE_CONFIG_DIR value required, e.g. ~/.claude-work}"
BROWSER_APP="${5:-}"
ICON_PATH="${6:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCURRENT_SCRIPT="$SCRIPT_DIR/build-desktop-concurrent.sh"
if [ ! -f "$CONCURRENT_SCRIPT" ]; then
  echo "build-desktop-concurrent.sh not found next to this script at $CONCURRENT_SCRIPT"
  exit 1
fi

UPDATER_APP_NAME="Update ${APP_NAME}"
APP_PATH="/Applications/${UPDATER_APP_NAME}.app"
BUNDLE_ID="com.$(whoami | tr -dc 'a-z0-9').update-$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Build the plain shell command first (real quotes), then AppleScript-escape
# it in one pass at the end — see build-desktop-launcher.sh for why doing
# this in two separate steps matters (mixing escaping contexts is a real,
# previously-hit bug).
SHELL_CMD="\"${CONCURRENT_SCRIPT}\" \"${APP_NAME}\" \"${CORE_INSTALL_DIR}\" \"${PROFILE_DIR}\" \"${CLAUDE_CONFIG_DIR_VALUE}\" \"${BROWSER_APP}\" \"${ICON_PATH}\"; echo; echo 'Done — you can close this window.'"
AS_ESCAPED="${SHELL_CMD//\"/\\\"}"

cat > "$WORKDIR/updater.applescript" <<EOF
tell application "Terminal"
    activate
    do script "${AS_ESCAPED}"
end tell
EOF

echo "== Compiling $UPDATER_APP_NAME =="
rm -rf "$APP_PATH"
osacompile -o "$APP_PATH" "$WORKDIR/updater.applescript"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${UPDATER_APP_NAME}" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_PATH/Contents/Info.plist"

echo "== Signing (ad-hoc) =="
codesign --force --deep -s - "$APP_PATH"

if [ -n "$ICON_PATH" ]; then
  if ! command -v fileicon >/dev/null 2>&1; then
    echo "fileicon not found — installing via Homebrew"
    brew install fileicon
  fi
  echo "== Applying icon (same one as the target app, so they look related) =="
  fileicon set "$APP_PATH" "$ICON_PATH"
fi

codesign -v "$APP_PATH" && echo "OK: $APP_PATH is ready — double-click it after any Claude Desktop update"

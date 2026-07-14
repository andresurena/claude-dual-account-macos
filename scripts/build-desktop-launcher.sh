#!/bin/zsh
#
# Builds a double-clickable macOS .app that launches the real Claude
# Desktop app with an isolated profile — separate cookies/session/login
# from your main install — and (optionally) routes its browser opens to
# a specific browser.
#
# This launches the SAME underlying app bundle your main Claude Desktop
# uses, just with a different Electron --user-data-dir. Because it's the
# same bundle identity, it can NOT run at the same time as your main
# Claude Desktop — only one instance per app identity runs concurrently
# on macOS. If you need both open simultaneously, see
# docs/desktop-concurrent-instances.md for the (unsupported, more
# involved) alternative.
#
# Usage:
#   ./build-desktop-launcher.sh "App Name" /path/to/profile-data-dir [browser-app-name] [icon.icns]
#
# Example:
#   ./build-desktop-launcher.sh "Claude Work Desktop" \
#       "$HOME/.claude-work/desktop-profile" "Microsoft Edge" "$HOME/my-icon.icns"

set -euo pipefail

APP_NAME="${1:?App display name required, e.g. \"Claude Work Desktop\"}"
PROFILE_DIR="${2:?Profile data directory required, e.g. ~/.claude-work/desktop-profile}"
BROWSER_APP="${3:-}"
ICON_PATH="${4:-}"

CLAUDE_APP="/Applications/Claude.app"
if [ ! -d "$CLAUDE_APP" ]; then
  echo "Claude.app not found at $CLAUDE_APP — install Claude Desktop first."
  exit 1
fi

APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.$(whoami | tr -dc 'a-z0-9').$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')"
BIN_DIR="$(dirname "$PROFILE_DIR")/bin"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$PROFILE_DIR"

# Build the actual shell command as plain text first — real quotes, and
# $PATH deliberately escaped (\$PATH) so it's evaluated when the launcher
# runs later, not expanded right now while building this script.
SHELL_CMD=""
if [ -n "$BROWSER_APP" ]; then
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/open" <<SHIM
#!/bin/zsh
exec /usr/bin/open -a "$BROWSER_APP" "\$@"
SHIM
  chmod +x "$BIN_DIR/open"
  SHELL_CMD="export PATH=\"${BIN_DIR}:\$PATH\"; "
fi
SHELL_CMD="${SHELL_CMD}nohup \"${CLAUDE_APP}/Contents/MacOS/Claude\" --user-data-dir=\"${PROFILE_DIR}\" > /dev/null 2>&1 &"

# Only now, once the plain shell command is fully built, apply AppleScript's
# own string-escaping (backslash before each double quote) — doing this in
# one pass at the end avoids mixing two different escaping contexts.
AS_ESCAPED="${SHELL_CMD//\"/\\\"}"

cat > "$WORKDIR/launcher.applescript" <<EOF
do shell script "${AS_ESCAPED}"
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
echo
echo "Note: this app shares Claude Desktop's app identity, so it can't run"
echo "at the same time as your main Claude Desktop install — quit one before"
echo "opening the other."

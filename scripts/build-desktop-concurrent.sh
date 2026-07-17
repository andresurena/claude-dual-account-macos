#!/bin/zsh
#
# ADVANCED / UNSUPPORTED. Read docs/desktop-concurrent-instances.md before
# using this.
#
# Duplicates and rebrands the entire Claude.app bundle so a second,
# independently-named instance can run AT THE SAME TIME as your main
# Claude Desktop install, each with its own icon and isolated profile.
#
# This works because macOS only allows one running instance per app
# *identity* (bundle ID) at a time — a plain --user-data-dir swap (see
# build-desktop-launcher.sh) isolates the data but keeps the same
# identity, so it still can't run alongside the original. Giving the
# duplicate its own bundle ID and product name is what unlocks true
# concurrency.
#
# Trade-offs, since this re-signs the duplicate ad-hoc (no real Developer
# ID):
#   - Code-signing entitlements are stripped. In practice this means any
#     sandboxed/entitlement-gated feature (e.g. Claude Desktop's local VM
#     / "computer use" sandbox) will report as unsupported in the
#     duplicate. Everyday chat/coding use is unaffected.
#   - It won't auto-update. Re-run this script after every Claude Desktop
#     update to refresh the duplicate.
#   - It's a ~700MB+ copy on disk.
#
# IMPORTANT: --user-data-dir only isolates the Electron web-session layer
# (cookies, localStorage, the chat UI's own login). It does NOT isolate
# the embedded Claude Code / agentic backend that Desktop's "Code"
# feature and any in-app /login use — that backend reads CLAUDE_CONFIG_DIR
# from the environment same as the CLI does, and silently falls back to
# your DEFAULT profile (usually Personal, ~/.claude) if it's unset. This
# was hit directly: a duplicate built without exporting CLAUDE_CONFIG_DIR
# looked correctly isolated for weeks — until a /login inside it quietly
# authenticated (and overwrote local state) as the OTHER profile. This
# script now requires you to pass it explicitly so that mistake can't
# happen silently again.
#
# Usage:
#   ./build-desktop-concurrent.sh "App Name" /path/to/core-install-dir /path/to/profile-data-dir /path/to/claude-config-dir [browser-app-name] [icon.icns]
#
# Example:
#   ./build-desktop-concurrent.sh "Claude Work Desktop" \
#       "$HOME/.claude-work/core" "$HOME/.claude-work/desktop-profile" \
#       "$HOME/.claude-work" "Microsoft Edge" "$HOME/my-icon.icns"

set -euo pipefail

APP_NAME="${1:?App display name required, e.g. \"Claude Work Desktop\"}"
CORE_INSTALL_DIR="${2:?Directory to hold the duplicated core app required, e.g. ~/.claude-work/core}"
PROFILE_DIR="${3:?Profile data directory required, e.g. ~/.claude-work/desktop-profile}"
CLAUDE_CONFIG_DIR_VALUE="${4:?CLAUDE_CONFIG_DIR value required, e.g. ~/.claude-work — isolates the embedded Code backend, not just the Electron profile. See the IMPORTANT note above.}"
BROWSER_APP="${5:-}"
ICON_PATH="${6:-}"

SOURCE_APP="/Applications/Claude.app"
if [ ! -d "$SOURCE_APP" ]; then
  echo "Claude.app not found at $SOURCE_APP — install Claude Desktop first."
  exit 1
fi

if [ -n "$ICON_PATH" ] && ! command -v fileicon >/dev/null 2>&1; then
  echo "fileicon not found — installing via Homebrew"
  brew install fileicon
fi

CORE_APP="$CORE_INSTALL_DIR/${APP_NAME}.app"
LAUNCHER_APP="/Applications/${APP_NAME}.app"
SLUG="$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')"
CORE_BUNDLE_ID="com.$(whoami | tr -dc 'a-z0-9').${SLUG}-core"
LAUNCHER_BUNDLE_ID="com.$(whoami | tr -dc 'a-z0-9').${SLUG}"
BIN_DIR="$(dirname "$PROFILE_DIR")/bin"

mkdir -p "$CORE_INSTALL_DIR" "$PROFILE_DIR"

echo "== Duplicating Claude.app (copies 700MB+, may take a moment) =="
rm -rf "$CORE_APP"
ditto "$SOURCE_APP" "$CORE_APP"

# Capture these BEFORE any renaming — the main executable filename does
# NOT need to change (macOS launches it directly by whatever
# CFBundleExecutable says); only the Helper .app bundles need renaming,
# because Electron looks them up by a name derived from CFBundleName.
ORIGINAL_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$CORE_APP/Contents/Info.plist")"
MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$CORE_APP/Contents/Info.plist")"

echo "== Renaming Helper apps to match (Electron looks these up by name) =="
FW="$CORE_APP/Contents/Frameworks"
find "$FW" -maxdepth 1 -iname "${ORIGINAL_NAME} Helper*.app" -print0 | while IFS= read -r -d '' helper; do
  base="$(basename "$helper" .app)"
  suffix="${base#${ORIGINAL_NAME} Helper}"   # e.g. " (GPU)", " (Renderer)", or ""
  newname="${APP_NAME} Helper${suffix}"
  newpath="$FW/${newname}.app"
  mv "$helper" "$newpath"
  mv "$newpath/Contents/MacOS/${base}" "$newpath/Contents/MacOS/${newname}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${newname}" "$newpath/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${newname}" "$newpath/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${newname}" "$newpath/Contents/Info.plist" 2>/dev/null || true
  suffix_id="$(echo "$suffix" | tr -dc 'a-zA-Z0-9')"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${CORE_BUNDLE_ID}.helper${suffix_id:+.$suffix_id}" "$newpath/Contents/Info.plist" 2>/dev/null || true
  echo "  ${base}.app -> ${newname}.app"
done

echo "== Rebranding main Info.plist =="
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$CORE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$CORE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${CORE_BUNDLE_ID}" "$CORE_APP/Contents/Info.plist"

if [ -n "$ICON_PATH" ]; then
  echo "== Replacing icon =="
  # Modern app bundles often ship a compiled asset catalog (Assets.car)
  # that takes precedence over the legacy CFBundleIconFile .icns, and it
  # isn't practically editable outside Xcode. Move it aside and drop the
  # CFBundleIconName key so the system falls back to the .icns file,
  # which we then overwrite directly.
  ICON_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$CORE_APP/Contents/Info.plist" 2>/dev/null || echo "")"
  if [ -f "$CORE_APP/Contents/Resources/Assets.car" ]; then
    mv "$CORE_APP/Contents/Resources/Assets.car" "$CORE_APP/Contents/Resources/Assets.car.bak"
  fi
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$CORE_APP/Contents/Info.plist" 2>/dev/null || true
  if [ -n "$ICON_NAME" ]; then
    ICON_FILE="$ICON_NAME"
    [[ "$ICON_FILE" == *.icns ]] || ICON_FILE="${ICON_FILE}.icns"
    cp "$ICON_PATH" "$CORE_APP/Contents/Resources/${ICON_FILE}"
  fi
fi

echo "== Signing duplicated core (ad-hoc, deep) =="
codesign --force --deep -s - "$CORE_APP"
codesign -v "$CORE_APP" && echo "core OK"

echo "== Building launcher app =="
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

SHELL_CMD="export CLAUDE_CONFIG_DIR=\"${CLAUDE_CONFIG_DIR_VALUE}\"; "
if [ -n "$BROWSER_APP" ]; then
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/open" <<SHIM
#!/bin/zsh
exec /usr/bin/open -a "$BROWSER_APP" "\$@"
SHIM
  chmod +x "$BIN_DIR/open"
  SHELL_CMD="${SHELL_CMD}export PATH=\"${BIN_DIR}:\$PATH\"; "
fi
SHELL_CMD="${SHELL_CMD}nohup \"${CORE_APP}/Contents/MacOS/${MAIN_EXECUTABLE}\" --user-data-dir=\"${PROFILE_DIR}\" > /dev/null 2>&1 &"
AS_ESCAPED="${SHELL_CMD//\"/\\\"}"

cat > "$WORKDIR/launcher.applescript" <<EOF
do shell script "${AS_ESCAPED}"
EOF

rm -rf "$LAUNCHER_APP"
osacompile -o "$LAUNCHER_APP" "$WORKDIR/launcher.applescript"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$LAUNCHER_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${LAUNCHER_BUNDLE_ID}" "$LAUNCHER_APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${LAUNCHER_BUNDLE_ID}" "$LAUNCHER_APP/Contents/Info.plist"
codesign --force --deep -s - "$LAUNCHER_APP"

if [ -n "$ICON_PATH" ]; then
  fileicon set "$LAUNCHER_APP" "$ICON_PATH"
fi

codesign -v "$LAUNCHER_APP" && echo "OK: $LAUNCHER_APP is valid and ready to launch"
echo
echo "This instance can now run at the same time as your main Claude Desktop."
echo "Re-run this whole script after every Claude Desktop update — the"
echo "duplicate is a point-in-time copy and won't auto-update."

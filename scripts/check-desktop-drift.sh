#!/bin/zsh
#
# Checks whether a concurrent duplicate built by build-desktop-concurrent.sh
# has fallen behind the real Claude Desktop install, and posts a macOS
# notification if so.
#
# The duplicate never auto-updates, and nothing else tells you it's stale
# — the first sign is usually a missing feature or model. Hit directly: a
# duplicate sat on 1.52386.6 for over a week after Claude.app moved to
# 2.7032.0, noticed only because a newly released model wasn't in its
# model picker.
#
# Usage:
#   ./check-desktop-drift.sh /path/to/core-install-dir/"App Name.app" [updater-app-name]
#
# Example:
#   ./check-desktop-drift.sh "$HOME/.claude-work/core/Claude Work Desktop.app" "Claude Work Updater"
#
# Always exits 0 — a stale duplicate is something to act on, not a
# failed job. See install-launchd-drift-check.sh to run this daily and at
# login.

set -euo pipefail

CORE_APP="${1:?Path to the duplicated core app required, e.g. ~/.claude-work/core/Claude Work Desktop.app}"
UPDATER_APP_NAME="${2:-}"
SOURCE_APP="/Applications/Claude.app"
APP_NAME="$(basename "$CORE_APP" .app)"

version_of() {
  # PlistBuddy prints "File Doesn't Exist, Will Create" to stdout and
  # exits 0 for a missing plist, so check existence first.
  [ -f "$1/Contents/Info.plist" ] || return 0
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true
}

SOURCE_VERSION="$(version_of "$SOURCE_APP")"
CORE_VERSION="$(version_of "$CORE_APP")"
echo "$(date '+%Y-%m-%d %H:%M:%S') Claude.app ${SOURCE_VERSION:-missing}, ${APP_NAME} ${CORE_VERSION:-missing}"

# Claude.app briefly disappears mid-update (Squirrel swaps the bundle) —
# nothing meaningful to compare against, so check again next run.
[ -z "$SOURCE_VERSION" ] && exit 0
[ "$SOURCE_VERSION" = "$CORE_VERSION" ] && exit 0

if [ -z "$CORE_VERSION" ]; then
  MESSAGE="${APP_NAME} isn't built at ${CORE_APP}."
else
  MESSAGE="Claude Desktop is on ${SOURCE_VERSION}, ${APP_NAME} is still on ${CORE_VERSION}."
fi
if [ -n "$UPDATER_APP_NAME" ]; then
  MESSAGE="${MESSAGE} Quit it and run ${UPDATER_APP_NAME}."
fi

# Passed as argv rather than interpolated into the AppleScript source, so
# app names never need AppleScript-escaping.
osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
  -e 'end run' \
  "$MESSAGE" "${APP_NAME} is out of date"
echo "  notified: $MESSAGE"

#!/bin/zsh
#
# Pins the claude:// URL scheme to a specific Claude-related app, so
# deep links always open a predictable app instead of whichever one
# macOS happens to guess (relevant once you have more than one
# Claude-branded .app installed).
#
# Usage:
#   ./pin-deep-link.sh /Applications/Claude.app

set -euo pipefail

APP_PATH="${1:?App path required, e.g. /Applications/Claude.app}"

if [ ! -d "$APP_PATH" ]; then
  echo "App not found: $APP_PATH"
  exit 1
fi

if ! command -v duti >/dev/null 2>&1; then
  echo "duti not found — installing via Homebrew"
  brew install duti
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")"
echo "Pinning claude:// to $BUNDLE_ID ($APP_PATH)"
duti -s "$BUNDLE_ID" claude

echo
echo "Verify:"
defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null \
  | grep -A3 'LSHandlerURLScheme = claude;' || true

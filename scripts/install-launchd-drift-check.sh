#!/bin/zsh
#
# Installs a macOS launchd user agent that runs check-desktop-drift.sh
# daily and at every login, so a concurrent duplicate that has fallen
# behind Claude Desktop gets flagged with a notification instead of
# going unnoticed until something is missing from it.
#
# Usage:
#   ./install-launchd-drift-check.sh /path/to/core-install-dir/"App Name.app" <hour> <minute> [updater-app-name]
#
# <hour> is 0-23, <minute> is 0-59, both in local time.
#
# Example (daily at 09:05 and at login):
#   ./install-launchd-drift-check.sh "$HOME/.claude-work/core/Claude Work Desktop.app" 9 5 "Claude Work Updater"
#
# Logs go to ~/Library/Logs/claude-desktop-drift-check.log.
#
# Re-running this script updates the schedule/args in place (unloads
# the old job first) — safe to re-run any time.

set -euo pipefail

CORE_APP="${1:?Path to the duplicated core app required, e.g. ~/.claude-work/core/Claude Work Desktop.app}"
HOUR="${2:?Hour (0-23) required}"
MINUTE="${3:?Minute (0-59) required}"
UPDATER_APP_NAME="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-desktop-drift.sh"
if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "check-desktop-drift.sh not found next to this script at $CHECK_SCRIPT"
  exit 1
fi

LABEL="com.$(whoami | tr -dc 'a-z0-9').claude-desktop-drift-check"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_PATH="$HOME/Library/Logs/claude-desktop-drift-check.log"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

if launchctl list "$LABEL" >/dev/null 2>&1; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# Separate <string> array elements, same as install-launchd-backup.sh —
# no shell-quoting to get wrong for app names with spaces.
UPDATER_ARG_XML=""
if [ -n "$UPDATER_APP_NAME" ]; then
  UPDATER_ARG_XML="
		<string>${UPDATER_APP_NAME}</string>"
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${CHECK_SCRIPT}</string>
		<string>${CORE_APP}</string>${UPDATER_ARG_XML}
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>${HOUR}</integer>
		<key>Minute</key>
		<integer>${MINUTE}</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${LOG_PATH}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_PATH}</string>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF

echo "== Loading launchd job: $LABEL =="
launchctl load "$PLIST_PATH"

echo
echo "OK: installed. Runs at login and daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") local time."
echo "Logs: $LOG_PATH"
echo
echo "To remove it:"
echo "  launchctl unload \"$PLIST_PATH\" && rm \"$PLIST_PATH\""

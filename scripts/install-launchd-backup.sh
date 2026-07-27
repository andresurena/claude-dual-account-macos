#!/bin/zsh
#
# Installs a macOS launchd user agent that runs
# backup-claude-sessions.sh automatically on a daily schedule, with
# optional retention (old archives beyond a count get pruned — see
# BACKUP_KEEP_LAST in backup-claude-sessions.sh).
#
# Runs independently of whether Claude Code or any terminal is open —
# it's a real launchd job, not something tied to an active session.
#
# Usage:
#   ./install-launchd-backup.sh <backup-dest-dir> <hour> <minute> <keep-last> <config-dir> [config-dir...]
#
# <hour> is 0-23, <minute> is 0-59, both in local time. <keep-last> is
# how many archives per profile to retain — pass 0 to keep everything
# forever (no pruning).
#
# Example (daily at 11:00, keep the last 14 of each profile):
#   ./install-launchd-backup.sh ~/Claude-Session-Backups 11 0 14 ~/.claude ~/.claude-work
#
# Logs go to ~/Library/Logs/claude-session-backup.log (stdout+stderr
# combined) so a failed run is debuggable without digging through
# launchd's own logging.
#
# Re-running this script updates the schedule/args in place (unloads
# the old job first) — safe to re-run any time.

set -euo pipefail

DEST_DIR="${1:?Backup destination directory required, e.g. ~/Claude-Session-Backups}"
HOUR="${2:?Hour (0-23) required}"
MINUTE="${3:?Minute (0-59) required}"
KEEP_LAST="${4:?Keep-last count required (0 = keep everything forever)}"
shift 4
if [ "$#" -eq 0 ]; then
  echo "At least one config directory required, e.g. ~/.claude or ~/.claude-work"
  exit 1
fi
CONFIG_DIRS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup-claude-sessions.sh"
if [ ! -f "$BACKUP_SCRIPT" ]; then
  echo "backup-claude-sessions.sh not found next to this script at $BACKUP_SCRIPT"
  exit 1
fi

LABEL="com.$(whoami | tr -dc 'a-z0-9').claude-session-backup"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_PATH="$HOME/Library/Logs/claude-session-backup.log"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Unload any existing copy of this job first, so re-running this script
# to change the schedule/args doesn't leave a stale job running alongside
# the new one.
if launchctl list "$LABEL" >/dev/null 2>&1; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# Built as real, separate <string> array elements — not a single shell
# command string — so there's no shell-quoting/escaping to get wrong for
# paths with spaces, and BACKUP_KEEP_LAST is passed via launchd's own
# EnvironmentVariables dict rather than an inline `VAR=value` prefix.
CONFIG_DIR_ARGS_XML=""
for d in "${CONFIG_DIRS[@]}"; do
  CONFIG_DIR_ARGS_XML="${CONFIG_DIR_ARGS_XML}
		<string>${d}</string>"
done

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BACKUP_SCRIPT}</string>
		<string>${DEST_DIR}</string>${CONFIG_DIR_ARGS_XML}
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>BACKUP_KEEP_LAST</key>
		<string>${KEEP_LAST}</string>
	</dict>
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
	<false/>
</dict>
</plist>
EOF

echo "== Loading launchd job: $LABEL =="
launchctl load "$PLIST_PATH"

echo
echo "OK: installed. Runs daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") local time."
if [ "$KEEP_LAST" = "0" ]; then
  echo "Retention: keeping every archive forever (no pruning)."
else
  echo "Retention: keeping the last $KEEP_LAST archives per profile."
fi
echo "Logs: $LOG_PATH"
echo
echo "To test it immediately instead of waiting for the scheduled time:"
echo "  launchctl start $LABEL"
echo
echo "To remove the recurring job entirely:"
echo "  launchctl unload \"$PLIST_PATH\" && rm \"$PLIST_PATH\""

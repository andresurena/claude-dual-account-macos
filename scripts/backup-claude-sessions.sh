#!/bin/zsh
#
# Backs up Claude Code session transcripts (the actual conversation
# history — what shows up when you resume a session) from one or more
# Claude config directories into timestamped, compressed archives.
#
# Deliberately scoped to just the `projects/` subdirectory of each config
# dir, not the whole thing — the config dir root also holds credentials
# and tokens (OAuth state, any files you've dropped in for service
# isolation per docs/service-isolation.md) that have no reason to be
# duplicated into a backup location.
#
# Usage:
#   ./backup-claude-sessions.sh <backup-dest-dir> <config-dir> [config-dir...]
#
# Example (backing up both a default and an isolated profile):
#   ./backup-claude-sessions.sh ~/Claude-Session-Backups ~/.claude ~/.claude-work
#
# Safe to run repeatedly (e.g. from a periodic job) — each run creates a
# new timestamped archive rather than overwriting the last one.

set -euo pipefail

DEST_DIR="${1:?Backup destination directory required, e.g. ~/Claude-Session-Backups}"
shift
if [ "$#" -eq 0 ]; then
  echo "At least one config directory required, e.g. ~/.claude or ~/.claude-work"
  exit 1
fi

mkdir -p "$DEST_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

for CONFIG_DIR in "$@"; do
  CONFIG_DIR="${CONFIG_DIR%/}"
  PROJECTS_DIR="$CONFIG_DIR/projects"
  if [ ! -d "$PROJECTS_DIR" ]; then
    echo "Skipping $CONFIG_DIR — no projects/ subdirectory found"
    continue
  fi
  LABEL="$(basename "$CONFIG_DIR" | tr -dc 'a-zA-Z0-9_-')"
  [ -z "$LABEL" ] && LABEL="claude"
  ARCHIVE="$DEST_DIR/${LABEL}-sessions-${TIMESTAMP}.tar.gz"
  echo "== Backing up $PROJECTS_DIR -> $ARCHIVE =="
  tar -czf "$ARCHIVE" -C "$CONFIG_DIR" projects
  echo "  $(du -h "$ARCHIVE" | cut -f1)"
done

echo
echo "Done. Archives in $DEST_DIR:"
ls -lh "$DEST_DIR"

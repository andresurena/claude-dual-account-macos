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
#
# Optional retention: set BACKUP_KEEP_LAST to an integer to automatically
# delete older archives beyond that count, per label (so Personal and
# Work archives are pruned independently, not competing for the same
# quota). Unset (the default) keeps every archive forever.
#
#   BACKUP_KEEP_LAST=14 ./backup-claude-sessions.sh ~/Claude-Session-Backups ~/.claude ~/.claude-work
#
# See scripts/install-launchd-backup.sh to run this automatically on a
# schedule instead of by hand.

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

  if [ -n "${BACKUP_KEEP_LAST:-}" ]; then
    # Sort by filename, not mtime (`ls -t`) — the YYYYMMDD-HHMMSS
    # timestamp in the name sorts correctly as a plain string and isn't
    # vulnerable to multiple archives landing within the same mtime
    # second (confirmed happening in testing: a handful of archives
    # created moments apart all shared one second-resolution mtime,
    # which would have made `ls -t`'s ordering unreliable/arbitrary).
    OLD_ARCHIVES=$(ls -1 "$DEST_DIR/${LABEL}-sessions-"*.tar.gz 2>/dev/null | sort -r | tail -n +$((BACKUP_KEEP_LAST + 1)))
    if [ -n "$OLD_ARCHIVES" ]; then
      echo "  Pruning older ${LABEL} archives beyond the last ${BACKUP_KEEP_LAST}:"
      echo "$OLD_ARCHIVES" | while IFS= read -r old; do
        echo "    removing $(basename "$old")"
        rm -f "$old"
      done
    fi
  fi
done

echo
echo "Done. Archives in $DEST_DIR:"
ls -lh "$DEST_DIR"

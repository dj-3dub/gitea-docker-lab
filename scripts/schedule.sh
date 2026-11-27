#!/usr/bin/env bash
# Schedule nightly backups in the current user's crontab (no sudo needed).
#
#   schedule.sh install   add/replace the entry (BACKUP_SCHEDULE in .env, default 03:30 daily)
#   schedule.sh remove    remove the entry
#   schedule.sh status    show the entry
#
# Each lab checkout gets its own entry, tagged with its path, so several
# labs on one machine do not clash. Output goes to backups/backup.log.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CRONTAB="${CRONTAB_CMD:-crontab}"   # overridable for tests
TAG="# gitea-lab-backup:${REPO_ROOT}"
load_env || true
SCHEDULE="${BACKUP_SCHEDULE:-30 3 * * *}"
BACKUP_DIR="${BACKUP_DIR:-backups}"

have "${CRONTAB%% *}" || die "crontab not found. Install cron (Debian/Ubuntu: sudo apt-get install cron)"

current() { $CRONTAB -l 2>/dev/null || true; }
# Read the whole crontab before writing, so other jobs can never be lost.
existing="$(current)"
without_entry() { [[ -z "$existing" ]] || grep -vF "$TAG" <<<"$existing" || true; }

case "${1:-}" in
  install)
    [[ "$(wc -w <<<"$SCHEDULE")" -eq 5 ]] || die "BACKUP_SCHEDULE must have 5 cron fields (got: $SCHEDULE)"
    mkdir -p "$BACKUP_DIR"
    line="$SCHEDULE cd '$REPO_ROOT' && ./scripts/backup.sh >> '$REPO_ROOT/$BACKUP_DIR/backup.log' 2>&1 $TAG"
    new_tab="$(without_entry; echo "$line")"
    $CRONTAB - <<<"$new_tab"
    pass "Scheduled: $SCHEDULE (log: $BACKUP_DIR/backup.log)"
    ;;
  remove)
    new_tab="$(without_entry)"
    $CRONTAB - <<<"$new_tab"
    pass "Backup schedule removed"
    ;;
  status)
    if entry="$(grep -F "$TAG" <<<"$existing")"; then
      pass "Scheduled: ${entry%% cd *}"
    else
      warn "No backup schedule (run: make schedule)"
    fi
    ;;
  *)
    die "Usage: $0 install | remove | status"
    ;;
esac

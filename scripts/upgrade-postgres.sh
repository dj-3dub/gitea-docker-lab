#!/usr/bin/env bash
# Move the database to a new PostgreSQL major version (e.g. 17 -> 19).
#
# A major version cannot read an older data directory, so this does a
# dump and restore. Only the database container and its volume are rebuilt;
# the Gitea data volume (repositories) is restored from the same backup.
#
#   1. set POSTGRES_VERSION in .env (e.g. 19-alpine)
#   2. make upgrade-postgres            (asks for confirmation; FORCE=1 skips)
#
# Downgrading needs the backup taken before the upgrade, because an older
# pg_restore cannot read a newer dump:
#   BACKUP=backups/<stamp> make upgrade-postgres
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_env
DB="$(db_ctr)"

container_running "$DB" || die "$DB is not running. Run: make up (with the current POSTGRES_VERSION)"

running_major="$(docker exec "$DB" sh -c 'echo "$PG_MAJOR"')"
target_major="${POSTGRES_VERSION%%[-.]*}"
[[ "$target_major" =~ ^[0-9]+$ ]] || die "Cannot read the major version from POSTGRES_VERSION=$POSTGRES_VERSION"

banner "PostgreSQL ${running_major} → ${target_major}"

if [[ "$running_major" == "$target_major" ]]; then
  pass "Already on PostgreSQL $running_major; nothing to do (minor updates: make update)"
  exit 0
fi
if (( target_major < running_major )) && [[ -z "${BACKUP:-}" ]]; then
  die "Downgrade needs the backup taken before the upgrade: BACKUP=backups/<stamp> make upgrade-postgres"
fi

q() { docker exec "$DB" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
fingerprint() {
  local t out=""
  for t in repository '"user"' issue comment label; do out+="$t=$(q "select count(*) from $t") "; done
  echo "$out"
}

if [[ "${FORCE:-0}" != 1 ]]; then
  echo "This takes a backup, then REBUILDS the database container and volume"
  echo "on PostgreSQL $target_major and restores the backup into it."
  read -r -p "Type 'upgrade' to continue: " answer
  [[ "$answer" == upgrade ]] || die "Aborted"
fi

if [[ -n "${BACKUP:-}" ]]; then
  [[ -d "$BACKUP" ]] || die "Backup not found: $BACKUP"
  backup="$BACKUP"
  expected=""
  info "Using existing backup $backup"
else
  expected="$(fingerprint)"
  info "Row counts before: $expected"
  info "Taking a backup first"
  ./scripts/backup.sh >/dev/null
  backup="$(find "${BACKUP_DIR:-backups}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}-[0-9]{6}' | sort | tail -n1)"
  pass "Backup: $backup"
fi

info "Rebuilding the database on PostgreSQL $target_major (new, empty volume)"
./scripts/tf.sh apply -input=false -auto-approve -replace=docker_volume.db_data >/dev/null
pass "PostgreSQL $(docker exec "$DB" sh -c 'echo "$PG_VERSION"') running"

# Gitea keeps running during the swap and logs "connection refused" /
# "relation does not exist" until the restore below stops it; expected.
info "Restoring $backup"
BACKUP="$backup" FORCE=1 ./scripts/restore.sh >/dev/null
pass "Restore complete"

if [[ -n "$expected" ]]; then
  actual="$(fingerprint)"
  if [[ "$actual" != "$expected" ]]; then
    fail "Row counts differ after the upgrade!"
    echo "  before: $expected"
    echo "  after:  $actual"
    echo "  Roll back: set POSTGRES_VERSION back to ${running_major}-alpine and run"
    echo "  BACKUP=$backup make upgrade-postgres"
    exit 1
  fi
  pass "Row counts match: $actual"
fi

pass "PostgreSQL ${running_major} → ${target_major} done. Keep $backup until you are happy."

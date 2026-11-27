#!/usr/bin/env bash
# Back up the Gitea lab: PostgreSQL dump, Gitea data volume (repos,
# attachments, app.ini, SSH host keys), .env, secrets/ and Terraform state.
#
#   BACKUP_DIR=backups        where backups go
#   BACKUP_KEEP=7             how many backups to keep (0 = keep all)
#   BACKUP_STOP_GITEA=1       (default) stop Gitea while backing up so the
#                             database and repositories match exactly; costs
#                             a few seconds of downtime. 0 = hot backup.
#   RESTIC_REPOSITORY=...     also upload the backup off-site (scripts/offsite.sh)
#   BACKUP_NOTIFY_URL=...     POST a message here if the backup fails (e.g. ntfy)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_env
umask 077

BACKUP_DIR="${BACKUP_DIR:-backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
BACKUP_STOP_GITEA="${BACKUP_STOP_GITEA:-1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${BACKUP_DIR}/${STAMP}"
WORK_DIR="${OUT_DIR}.partial"
GITEA="$(gitea_ctr)"
DB="$(db_ctr)"

stopped_gitea=0
cleanup() {
  local rc=$?
  [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  if [[ "$stopped_gitea" == 1 ]]; then docker start "$GITEA" >/dev/null 2>&1 || true; fi
  if [[ "$rc" -ne 0 && -n "${BACKUP_NOTIFY_URL:-}" ]]; then
    curl -fsS -m 10 -d "Gitea lab backup FAILED on $(hostname) (exit $rc). See backups/backup.log" \
      "$BACKUP_NOTIFY_URL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

container_running "$DB" || die "$DB is not running. Run: make up"
mkdir -p "$WORK_DIR"

banner "Gitea Lab Backup → $OUT_DIR"

if [[ "$BACKUP_STOP_GITEA" == 1 ]] && container_running "$GITEA"; then
  info "Stopping $GITEA for a consistent snapshot"
  docker stop "$GITEA" >/dev/null
  stopped_gitea=1
fi

info "Dumping PostgreSQL database '${POSTGRES_DB}'"
docker exec "$DB" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$WORK_DIR/db.dump"
pass "db.dump ($(du -h "$WORK_DIR/db.dump" | cut -f1))"

info "Archiving volume $(gitea_volume)"
with_gitea_volume ro tar -czf - -C /data . > "$WORK_DIR/gitea-data.tar.gz"
pass "gitea-data.tar.gz ($(du -h "$WORK_DIR/gitea-data.tar.gz" | cut -f1))"

if [[ "$stopped_gitea" == 1 ]]; then
  info "Restarting $GITEA"
  docker start "$GITEA" >/dev/null
  stopped_gitea=0
  wait_healthy "$GITEA"
  pass "$GITEA healthy again"
fi

cp "$ENV_FILE" "$WORK_DIR/env.backup"
pass "env.backup"
mkdir -p "$WORK_DIR/secrets"
cp "$SECRETS_DIR"/* "$WORK_DIR/secrets/"
pass "secrets/"
if [[ -f terraform/terraform.tfstate ]]; then
  cp terraform/terraform.tfstate "$WORK_DIR/terraform.tfstate"
  pass "terraform.tfstate"
fi

cat > "$WORK_DIR/manifest.txt" <<EOF
created=$(date -Iseconds)
host=$(hostname)
project_version=$(cat VERSION 2>/dev/null || echo unknown)
gitea_version=${GITEA_VERSION:-unknown}
postgres_version=${POSTGRES_VERSION:-unknown}
postgres_db=${POSTGRES_DB}
EOF
sums="$(cd "$WORK_DIR" && find . -type f -printf '%P\n' | sort | xargs -d '\n' sha256sum --)"
printf '%s\n' "$sums" > "$WORK_DIR/SHA256SUMS"

mv "$WORK_DIR" "$OUT_DIR"
pass "Backup complete: $OUT_DIR"

if [[ "$BACKUP_KEEP" -gt 0 ]]; then
  mapfile -t old < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}-[0-9]{6}' | sort | head -n -"$BACKUP_KEEP")
  for dir in "${old[@]}"; do
    rm -rf -- "$dir"
    info "Pruned old backup $(basename "$dir")"
  done
fi

if [[ -n "${RESTIC_REPOSITORY:-}" && "${BACKUP_OFFSITE:-1}" == 1 ]]; then
  ./scripts/offsite.sh push "$OUT_DIR"
fi

#!/usr/bin/env bash
# Restore a backup made by scripts/backup.sh. This REPLACES the current
# Gitea database and data volume. The lab must be up (make up).
#
#   BACKUP=backups/20260101-120000 ./scripts/restore.sh
#   BACKUP=latest FORCE=1 ./scripts/restore.sh     # no confirmation prompt
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_env
BACKUP_DIR="${BACKUP_DIR:-backups}"
BACKUP="${BACKUP:-}"
GITEA="$(gitea_ctr)"
DB="$(db_ctr)"

list_backups() {
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort || true
}

if [[ -z "$BACKUP" ]]; then
  echo "Available backups:"
  list_backups | sed 's/^/  /'
  echo ""
  echo "Usage: make restore BACKUP=<dir>   (or BACKUP=latest)"
  exit 1
fi
[[ "$BACKUP" == latest ]] && BACKUP="$(list_backups | tail -n1)"
[[ -d "$BACKUP" ]] || die "Backup not found: ${BACKUP:-<none>}"

banner "Gitea Lab Restore ← $BACKUP"

for f in db.dump gitea-data.tar.gz SHA256SUMS; do
  [[ -f "$BACKUP/$f" ]] || die "$BACKUP/$f missing"
done
(cd "$BACKUP" && sha256sum --quiet -c SHA256SUMS) || die "Checksum verification failed"
pass "Checksums verified"

if ! container_exists "$GITEA" || ! container_running "$DB"; then
  die "Lab is not up. Run: make up"
fi

if [[ "${FORCE:-0}" != 1 ]]; then
  echo ""
  echo "This will REPLACE the current Gitea database and repositories."
  read -r -p "Type 'restore' to continue: " answer
  [[ "$answer" == restore ]] || die "Aborted"
fi

# Gitea encrypts some data (2FA, secrets) with SECRET_KEY; it must match.
# Changing it in .env means Terraform must recreate the Gitea container.
key_changed=0
if [[ -f "$BACKUP/env.backup" ]]; then
  old_key="$(grep -E '^GITEA_SECRET_KEY=' "$BACKUP/env.backup" | cut -d= -f2- || true)"
  if [[ -n "$old_key" && "$old_key" != "${GITEA_SECRET_KEY:-}" ]]; then
    cp "$ENV_FILE" "${ENV_FILE}.pre-restore"
    set_env_var GITEA_SECRET_KEY "$old_key"
    key_changed=1
    info "Adopted GITEA_SECRET_KEY from backup (previous .env saved as ${ENV_FILE}.pre-restore)"
  fi
fi

info "Stopping $GITEA"
docker stop "$GITEA" >/dev/null

info "Recreating database '${POSTGRES_DB}'"
psql_admin() { docker exec -i "$DB" psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d postgres "$@"; }
psql_admin -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\" WITH (FORCE);"
psql_admin -c "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"
docker exec -i "$DB" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --role="$POSTGRES_USER" \
  < "$BACKUP/db.dump"
pass "Database restored"

info "Restoring volume $(gitea_volume)"
with_gitea_volume rw sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -xzf - -C /data' \
  < "$BACKUP/gitea-data.tar.gz"
pass "Data volume restored"

if [[ "$key_changed" == 1 ]]; then
  info "Applying new SECRET_KEY with Terraform"
  ./scripts/tf.sh apply -auto-approve -input=false >/dev/null
else
  docker start "$GITEA" >/dev/null
fi
wait_healthy "$GITEA"
pass "Restore complete; $GITEA healthy"

if [[ -f "$BACKUP/terraform.tfstate" && ! -f terraform/terraform.tfstate ]]; then
  echo ""
  echo "Note: this backup contains Terraform state from the original host:"
  echo "  $BACKUP/terraform.tfstate"
fi

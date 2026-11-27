#!/usr/bin/env bash
# Create the initial Gitea admin account from .env (idempotent).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_env
: "${GITEA_ADMIN_USER:?GITEA_ADMIN_USER is not set in .env}"
: "${GITEA_ADMIN_EMAIL:?GITEA_ADMIN_EMAIL is not set in .env}"
: "${GITEA_ADMIN_PASSWORD:?GITEA_ADMIN_PASSWORD is not set in .env}"

ctr="$(gitea_ctr)"
container_running "$ctr" || die "$ctr is not running. Run: make up"

gitea_cli() { docker exec -u git "$ctr" gitea "$@"; }

if gitea_cli admin user list --admin | awk 'NR > 1 { print $2 }' | grep -qxF "$GITEA_ADMIN_USER"; then
  pass "Admin user '$GITEA_ADMIN_USER' already exists"
  exit 0
fi

gitea_cli admin user create \
  --admin \
  --username "$GITEA_ADMIN_USER" \
  --email "$GITEA_ADMIN_EMAIL" \
  --password "$GITEA_ADMIN_PASSWORD" \
  --must-change-password=false >/dev/null

pass "Created admin user '$GITEA_ADMIN_USER'"
echo "  Password: GITEA_ADMIN_PASSWORD in $ENV_FILE"

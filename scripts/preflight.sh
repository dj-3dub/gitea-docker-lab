#!/usr/bin/env bash
# Safety checks before `make up` / `make apply` / `make update`.
#
# Refuses to continue when POSTGRES_VERSION names a different major version
# than the one that wrote the existing database volume. A plain apply would
# start the new major on an empty data directory, and Gitea would come up
# with an empty database (the old data stays in the volume, unused).
# `make upgrade-postgres` does the dump/restore properly.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

load_env || exit 0                      # no .env yet: nothing to protect
volume="$(lab_name)-db-data"
target="${POSTGRES_VERSION:-19-alpine}"
target_major="${target%%[-.]*}"

docker volume inspect "$volume" >/dev/null 2>&1 || exit 0   # fresh install

# PG_VERSION sits at the volume root for <= 17, and in <major>/docker/ for 18+.
data_major="$(docker run --rm -v "$volume:/v:ro" --entrypoint sh "postgres:$target" -c \
  'cat /v/PG_VERSION /v/*/docker/PG_VERSION 2>/dev/null | sort -n | tail -n1' 2>/dev/null || true)"

[[ -z "$data_major" || "$data_major" == "$target_major" ]] && exit 0

echo "✗ The database volume $volume holds PostgreSQL $data_major data, but"
echo "  POSTGRES_VERSION=$target (major $target_major). Applying this would start an"
echo "  EMPTY database. To change major version, use the upgrade path instead:"
echo ""
echo "    1. set POSTGRES_VERSION back to ${data_major}-alpine and run: make up"
echo "    2. set POSTGRES_VERSION=$target and run:              make upgrade-postgres"
exit 1

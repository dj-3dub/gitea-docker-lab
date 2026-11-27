#!/usr/bin/env bash
# End-to-end test of a running lab: push a repo, back up, delete the repo,
# restore, and check the commit came back.
#
# DESTRUCTIVE: the restore step replaces the current database and data
# with the backup taken moments earlier. Meant for CI or throwaway labs.
#   FORCE=1 ./scripts/smoke-test.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ "${FORCE:-0}" == 1 ]] || die "Destructive test (runs a restore). Re-run with FORCE=1."
require_env

BASE="http://127.0.0.1:${GITEA_HTTP_PORT:-3000}"
AUTH="${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}"
REPO="smoke-$(date +%s)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

api() { curl -fsS -u "$AUTH" -H 'Content-Type: application/json' "$@"; }

banner "Gitea Lab Smoke Test"

api -d "{\"name\":\"${REPO}\"}" "$BASE/api/v1/user/repos" >/dev/null
pass "created repo $REPO"

git -C "$WORK" init -q -b main
echo "smoke test" > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" -c user.name=smoke -c user.email=smoke@example.com commit -qm "smoke commit"
git -C "$WORK" push -q "http://${AUTH}@127.0.0.1:${GITEA_HTTP_PORT:-3000}/${GITEA_ADMIN_USER}/${REPO}.git" main
pass "pushed commit over HTTP"

./scripts/backup.sh >/dev/null
pass "backup taken"

api -X DELETE "$BASE/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}"
code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$BASE/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}")"
[[ "$code" == 404 ]] || die "repo still present after delete (HTTP $code)"
pass "repo deleted"

BACKUP=latest FORCE=1 ./scripts/restore.sh >/dev/null
pass "restore completed"

msg="$(api "$BASE/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}/commits?limit=1" \
  | grep -o '"message":"[^"]*"' | head -n1 | cut -d'"' -f4)"
[[ "$msg" == "smoke commit"* ]] || die "restored repo has unexpected commit: '${msg}'"
pass "restored repo has the pushed commit"

api -X DELETE "$BASE/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}"
pass "cleaned up"

summary

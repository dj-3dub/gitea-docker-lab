#!/usr/bin/env bash
# Check that the Gitea lab is up, reachable and matches Terraform.
# Exits non-zero on failure.  HEALTH_SKIP_TF=1 skips the drift check.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

banner "Gitea Lab Health Check"

load_env || warn "$ENV_FILE not found; using defaults"
HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
SSH_PORT="${GITEA_SSH_PORT:-2222}"

section "Docker"
if docker info >/dev/null 2>&1; then
  pass "Docker engine running"
else
  fail "Docker engine not running"
  summary || exit 1
fi

section "Containers"
for ctr in "$(gitea_ctr)" "$(db_ctr)"; do
  if ! container_exists "$ctr"; then
    fail "$ctr: missing (run: make up)"
  elif ! container_running "$ctr"; then
    fail "$ctr: $(docker inspect -f '{{.State.Status}}' "$ctr")"
  else
    health="$(container_health "$ctr")"
    case "$health" in
      healthy|"") pass "$ctr: running${health:+ ($health)}" ;;
      starting)   warn "$ctr: running (health: starting)" ;;
      *)          fail "$ctr: running (health: $health)" ;;
    esac
  fi
done

section "Endpoints"
if curl -fsS --max-time 5 "http://127.0.0.1:${HTTP_PORT}/api/healthz" >/dev/null 2>&1; then
  pass "HTTP  http://127.0.0.1:${HTTP_PORT}/api/healthz"
else
  fail "HTTP  http://127.0.0.1:${HTTP_PORT}/api/healthz not responding"
fi

# Read only the server's greeting line; SSH then waits for the client, so
# reading a fixed byte count would block until the timeout.
# shellcheck disable=SC2016  # $1 expands in the inner shell (the port argument)
ssh_banner="$(timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" && IFS= read -r line <&3 && printf "%s\n" "$line"' _ "$SSH_PORT" 2>/dev/null || true)"
if [[ "$ssh_banner" == SSH-* ]]; then
  pass "SSH   127.0.0.1:${SSH_PORT} (${ssh_banner%$'\r'})"
else
  fail "SSH   127.0.0.1:${SSH_PORT} not answering"
fi

if [[ "${HEALTH_SKIP_TF:-0}" != 1 ]]; then
  section "Terraform"
  set +e
  ./scripts/tf.sh plan -detailed-exitcode -input=false -lock=false >/dev/null 2>&1 </dev/null
  rc=$?
  set -e
  case "$rc" in
    0) pass "No drift: running lab matches terraform/ and .env" ;;
    2) warn "Drift: run 'make plan' to see differences, 'make up' to fix" ;;
    *) warn "terraform plan failed (run: make plan)" ;;
  esac
fi

section "Backups"
backup_dir="${BACKUP_DIR:-backups}"
latest="$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
  -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort | tail -n1 || true)"
if [[ -z "$latest" ]]; then
  warn "No backups yet (run: make backup)"
else
  age_h=$(( ($(date +%s) - $(stat -c %Y "$latest")) / 3600 ))
  if [[ "$age_h" -le 48 ]]; then
    pass "Latest backup $(basename "$latest") (${age_h}h old)"
  else
    warn "Latest backup $(basename "$latest") is ${age_h}h old"
  fi
fi

free_pct=$(df -P . | awk 'NR == 2 { gsub("%", "", $5); print 100 - $5 }')
if [[ "$free_pct" -ge 10 ]]; then pass "Disk ${free_pct}% free"; else warn "Disk only ${free_pct}% free"; fi

summary

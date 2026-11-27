#!/usr/bin/env bash
# Prepare a fresh checkout: check tools, create .env, generate secrets.
# Safe to re-run: existing values in .env are never overwritten.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

banner "Gitea Lab Bootstrap"

section "Required tools"
for cmd in docker git make curl openssl; do
  if have "$cmd"; then pass "$cmd"; else fail "$cmd missing (run: make install)"; fi
done
if docker info >/dev/null 2>&1; then
  pass "docker engine reachable"
else
  fail "docker engine not reachable (is the daemon running / are you in the docker group?)"
fi

section "Optional tools"
for cmd in terraform ansible shellcheck yamllint; do
  if have "$cmd"; then pass "$cmd"; else warn "$cmd not installed"; fi
done
have terraform || info "Terraform not installed: it will run in the hashicorp/terraform container."

section "Environment file"
if [[ -f "$ENV_FILE" ]]; then
  pass "$ENV_FILE exists"
else
  [[ -f .env.example ]] || die ".env.example missing; cannot create $ENV_FILE"
  (umask 077 && cp .env.example "$ENV_FILE")
  pass "$ENV_FILE created from .env.example"
fi
chmod 600 "$ENV_FILE"

# Replace each __GENERATE__ placeholder with its own random value.
generated=0
while IFS= read -r key; do
  set_env_var "$key" "$(openssl rand -hex 24)"
  info "generated $key"
  generated=$((generated + 1))
done < <(grep -E '^[A-Z0-9_]+=__GENERATE__$' "$ENV_FILE" | cut -d= -f1)
[[ "$generated" -gt 0 ]] || pass "no secrets left to generate"

# Match the data volume owner to the current user on first run.
if grep -qE '^USER_UID=1000$' "$ENV_FILE" && [[ "$(id -u)" != 1000 ]]; then
  set_env_var USER_UID "$(id -u)"
  set_env_var USER_GID "$(id -g)"
  info "set USER_UID/USER_GID to $(id -u):$(id -g)"
fi

section "Script permissions"
chmod +x scripts/*.sh
pass "scripts/*.sh executable"

echo ""
if summary; then
  echo ""
  echo "Next steps:"
  echo "  1. Review .env (ports, domain, admin e-mail)"
  echo "  2. make build      # validate → terraform apply → admin → health"
else
  exit 1
fi

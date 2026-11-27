#!/usr/bin/env bash
# Static validation of the project. Exits non-zero on any failure.
# STRICT=1 also turns missing optional linters into failures (used by CI).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

STRICT="${STRICT:-0}"
indent() { sed 's/^/    /'; }
missing_tool() { if [[ "$STRICT" == 1 ]]; then fail "$1"; else warn "$1"; fi; }

banner "Gitea Lab Validation"

section "Project files"
for f in README.md Makefile VERSION .env.example .gitignore .yamllint \
  scripts/lib.sh scripts/install.sh scripts/bootstrap.sh scripts/validate.sh \
  scripts/healthcheck.sh scripts/backup.sh scripts/restore.sh scripts/tf.sh \
  scripts/create-admin.sh scripts/smoke-test.sh \
  ansible/ansible.cfg ansible/inventory/hosts.ini ansible/playbooks/deploy.yml \
  ansible/roles/project_host/tasks/main.yml \
  terraform/versions.tf terraform/main.tf terraform/variables.tf \
  terraform/outputs.tf terraform/.terraform.lock.hcl \
  .github/workflows/validate.yml; do
  if [[ -f "$f" ]]; then pass "$f"; else fail "$f missing"; fi
done

section "Environment"
if [[ -f "$ENV_FILE" ]]; then
  pass "$ENV_FILE present"
  perms="$(stat -c %a "$ENV_FILE")"
  if [[ "$perms" == 600 ]]; then pass "$ENV_FILE permissions 600"; else warn "$ENV_FILE permissions $perms (expected 600)"; fi
  if grep -qE '^[A-Z0-9_]+=__GENERATE__$' "$ENV_FILE"; then
    fail "$ENV_FILE still has __GENERATE__ placeholders (run: make bootstrap)"
  else
    pass "secrets generated"
  fi
  for key in POSTGRES_PASSWORD GITEA_SECRET_KEY GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD; do
    if grep -qE "^${key}=.+" "$ENV_FILE"; then pass "$key set"; else fail "$key empty"; fi
  done
else
  warn "$ENV_FILE missing (run: make bootstrap)"
fi

section "Docker"
if ! have docker; then
  fail "docker not installed"
elif docker info >/dev/null 2>&1; then
  pass "docker engine reachable"
else
  fail "docker engine not reachable"
fi

section "Shell scripts"
if have shellcheck; then
  if out="$(shellcheck -x -P scripts scripts/*.sh 2>&1)"; then
    pass "shellcheck"
  else
    fail "shellcheck found issues:"
    indent <<<"$out"
  fi
else
  missing_tool "shellcheck not installed"
fi
for f in scripts/*.sh; do
  [[ "$f" == scripts/lib.sh || -x "$f" ]] || fail "$f not executable"
done

section "YAML"
if have yamllint; then
  if out="$(yamllint -s . 2>&1)"; then pass "yamllint"; else fail "yamllint found issues:"; indent <<<"$out"; fi
else
  missing_tool "yamllint not installed"
fi

section "Terraform ($(have terraform && [[ "${TF_MODE:-auto}" != docker ]] && echo local || echo container))"
if have terraform || have docker; then
  if ./scripts/tf.sh fmt -check -recursive >/dev/null 2>&1; then
    pass "terraform fmt"
  else
    fail "terraform fmt needed (run: make tf-fmt)"
  fi
  if ! ./scripts/tf.sh init -backend=false -input=false >/dev/null 2>&1; then
    fail "terraform init failed (run: make tf-init)"
  elif out="$(./scripts/tf.sh validate -no-color 2>&1)"; then
    pass "terraform validate"
  else
    fail "terraform validate failed:"
    indent <<<"$out"
  fi
else
  fail "neither terraform nor docker available"
fi

section "Ansible"
if have ansible-playbook; then
  if out="$(ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/playbooks/deploy.yml --syntax-check 2>&1)"; then
    pass "ansible syntax check"
  else
    fail "ansible syntax check failed:"
    indent <<<"$out"
  fi
else
  missing_tool "ansible-playbook not installed"
fi

summary

#!/usr/bin/env bash
# Run Terraform against terraform/, locally if installed, otherwise in the
# hashicorp/terraform container (with the Docker socket mounted).
#
#   TF_MODE=auto    (default) local terraform if found, else container
#   TF_MODE=local   require a local terraform
#   TF_MODE=docker  always use the container
#
# Settings in .env are passed to Terraform as TF_VAR_* variables, so .env
# is the only file you edit.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TF_DIR="terraform"
TF_MODE="${TF_MODE:-auto}"

load_env || true

# .env key -> Terraform variable. Unset/empty keys fall back to the
# variable defaults in terraform/variables.tf.
declare -A TF_VARS=(
  [LAB_NAME]=lab_name
  [GITEA_VERSION]=gitea_version
  [POSTGRES_VERSION]=postgres_version
  [USER_UID]=user_uid
  [USER_GID]=user_gid
  [TZ]=timezone
  [GITEA_DOMAIN]=gitea_domain
  [GITEA_ROOT_URL]=gitea_root_url
  [GITEA_SSH_DOMAIN]=gitea_ssh_domain
  [GITEA_HTTP_BIND]=http_bind
  [GITEA_HTTP_PORT]=http_port
  [GITEA_SSH_BIND]=ssh_bind
  [GITEA_SSH_PORT]=ssh_port
  [GITEA_SECRET_KEY]=gitea_secret_key
  [GITEA_DISABLE_REGISTRATION]=disable_registration
  [GITEA_REQUIRE_SIGNIN_VIEW]=require_signin_view
  [GITEA_LOG_LEVEL]=log_level
  [POSTGRES_DB]=postgres_db
  [POSTGRES_USER]=postgres_user
  [POSTGRES_PASSWORD]=postgres_password
)
env_args=()
for key in "${!TF_VARS[@]}"; do
  if [[ -n "${!key:-}" ]]; then
    export "TF_VAR_${TF_VARS[$key]}=${!key}"
    env_args+=(-e "TF_VAR_${TF_VARS[$key]}")
  fi
done

case "$TF_MODE" in
  auto)   if have terraform; then TF_MODE=local; else TF_MODE=docker; fi ;;
  local)  have terraform || die "TF_MODE=local but terraform is not installed" ;;
  docker) ;;
  *)      die "TF_MODE must be auto, local or docker (got: $TF_MODE)" ;;
esac

# State holds the database password and secret key: keep it private.
umask 077
lock_state() { chmod 600 "$TF_DIR"/terraform.tfstate* 2>/dev/null || true; }

if [[ "$TF_MODE" == local ]]; then
  rc=0
  terraform -chdir="$TF_DIR" "$@" || rc=$?
  lock_state
  exit "$rc"
fi

# ---------- Container mode ----------
have docker || die "Neither terraform nor docker is available"

socket=/var/run/docker.sock
if [[ "${DOCKER_HOST:-}" == unix://* ]]; then
  socket="${DOCKER_HOST#unix://}"
elif [[ -n "${DOCKER_HOST:-}" ]]; then
  env_args+=(-e DOCKER_HOST)   # tcp:// or ssh:// engines are used as-is
fi
[[ -S "$socket" ]] || [[ -n "${DOCKER_HOST:-}" && "${DOCKER_HOST}" != unix://* ]] \
  || die "Docker socket not found at $socket"

tty_args=(-i)
[[ -t 0 && -t 1 ]] && tty_args=(-it)

rc=0
docker run --rm "${tty_args[@]}" \
  --user "$(id -u):$(id -g)" \
  --group-add "$(stat -c %g "$socket" 2>/dev/null || echo 0)" \
  -v "$socket:/var/run/docker.sock" \
  -v "$REPO_ROOT/$TF_DIR:/workspace" \
  -w /workspace \
  -e HOME=/tmp \
  -e TF_IN_AUTOMATION=1 \
  "${env_args[@]}" \
  "hashicorp/terraform:${TERRAFORM_VERSION:-1.17.2}" "$@" || rc=$?
lock_state
exit "$rc"

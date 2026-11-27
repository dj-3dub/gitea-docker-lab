# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source it, do not execute it.

# Always operate from the repository root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

ENV_FILE="${ENV_FILE:-.env}"
# Secrets live in files (mode 600), never in .env or Terraform state.
SECRETS_DIR="${SECRETS_DIR:-secrets}"
# shellcheck disable=SC2034  # used by the scripts that source this file
SECRET_NAMES=(postgres_password gitea_secret_key restic_password)

PASSED=0
WARNINGS=0
FAILED=0

pass() { echo "✓ $*"; PASSED=$((PASSED + 1)); }
warn() { echo "⚠ $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "✗ $*"; FAILED=$((FAILED + 1)); }
info() { echo "→ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

section() {
  echo ""
  echo "$1"
  printf '%*s\n' "${#1}" '' | tr ' ' '-'
}

banner() {
  echo "===================================================="
  echo "$1"
  echo "===================================================="
}

# Print the totals and return non-zero if anything failed.
summary() {
  section "Result"
  echo "Passed:   $PASSED"
  echo "Warnings: $WARNINGS"
  echo "Failed:   $FAILED"
  [[ "$FAILED" -eq 0 ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# Export every KEY=value from .env into the environment. Variables already
# set in the environment win (e.g. `BACKUP_STOP_GITEA=0 make backup`), the
# same precedence Docker Compose uses.
load_env() {
  local file="${1:-$ENV_FILE}" name
  [[ -f "$file" ]] || return 1
  local -A keep=()
  while IFS= read -r name; do
    [[ -n "${!name+x}" ]] && keep[$name]="${!name}"
  done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$file" | tr -d '=')
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  for name in "${!keep[@]}"; do export "$name=${keep[$name]}"; done
}

require_env() {
  load_env || die "$ENV_FILE not found. Run: make bootstrap"
}

# Set KEY=value in .env, replacing an existing line or appending one.
set_env_var() {
  local key="$1" value="$2" file="${3:-$ENV_FILE}" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  KEY="$key" VALUE="$value" awk '
    BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; done = 0 }
    index($0, key "=") == 1 { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

read_secret() { cat "$SECRETS_DIR/$1"; }

# ---------- Lab resources (names must match terraform/main.tf) ----------
lab_name()        { echo "${LAB_NAME:-gitea-lab}"; }
gitea_ctr()       { echo "$(lab_name)-gitea"; }
db_ctr()          { echo "$(lab_name)-db"; }
gitea_volume()    { echo "$(lab_name)-gitea-data"; }
gitea_image()     { echo "docker.gitea.com/gitea:${GITEA_VERSION:-1.27.3}"; }

container_exists()  { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }
container_health()  { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null; }

# Wait until a container reports healthy (default 180 s).
wait_healthy() {
  local ctr="$1" timeout="${2:-180}" waited=0
  until [[ "$(container_health "$ctr")" == healthy ]]; do
    (( waited >= timeout )) && die "$ctr not healthy after ${timeout}s"
    sleep 2
    waited=$((waited + 2))
  done
}

# Run a throwaway container from the Gitea image with the data volume at /data.
with_gitea_volume() {
  local mode="$1"; shift
  docker run --rm -i -v "$(gitea_volume):/data:${mode}" --entrypoint "$1" "$(gitea_image)" "${@:2}"
}

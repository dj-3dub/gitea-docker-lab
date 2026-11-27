#!/usr/bin/env bash
# Compare the image versions pinned in .env.example with the latest releases.
#
#   check-updates.sh             print a table (exit 0)
#   check-updates.sh --strict    exit 10 if anything is out of date (used by CI)
#   check-updates.sh --markdown  print a Markdown table (used for the CI issue)
#
# Uses the GitHub releases API (GITHUB_TOKEN raises the rate limit if set)
# and Docker Hub for PostgreSQL major versions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MODE="${1:-}"
pinned() { grep -oP "^$1=\"?\K[^\"]+" .env.example; }

gh_latest() {
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsS -m 20 "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" \
    | grep -oP '"tag_name":\s*"v?\K[^"]+'
}

# True if $2 is a newer version than $1.
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$2" ]]; }

rows=()
outdated=0
add() {  # name pinned latest note
  local status="up to date"
  if newer "$2" "$3"; then status="UPDATE"; outdated=$((outdated + 1)); fi
  rows+=("$1|$2|$3|$status|$4")
}

add "Gitea"     "$(pinned GITEA_VERSION)"     "$(gh_latest go-gitea/gitea)"       "GITEA_VERSION — read the release notes; take a backup first (make update does)"
add "Terraform" "$(pinned TERRAFORM_VERSION)" "$(gh_latest hashicorp/terraform)"  "TERRAFORM_VERSION — container image only"
add "restic"    "$(pinned RESTIC_VERSION)"    "$(gh_latest restic/restic)"        "RESTIC_VERSION — off-site backups"

# PostgreSQL floats on a major tag (e.g. 19-alpine gets minor updates on
# `make update`); only a new major needs action, and it needs a dump/restore.
pg="$(pinned POSTGRES_VERSION)"; pg_major="${pg%%-*}"; pg_suffix="${pg#"$pg_major"}"
pg_latest="$pg_major"
for next in $((pg_major + 1)) $((pg_major + 2)); do
  if curl -fsS -m 20 -o /dev/null "https://hub.docker.com/v2/repositories/library/postgres/tags/${next}${pg_suffix}" 2>/dev/null; then
    pg_latest="$next"
  fi
done
add "PostgreSQL" "$pg_major" "$pg_latest" "POSTGRES_VERSION — major upgrade needs dump/restore (docs/operations.md)"

if [[ "$MODE" == --markdown ]]; then
  echo "| Component | Pinned | Latest | Status | Where |"
  echo "|---|---|---|---|---|"
  for r in "${rows[@]}"; do IFS='|' read -r n p l s w <<<"$r"; echo "| $n | \`$p\` | \`$l\` | $s | $w |"; done
else
  printf '%-11s %-12s %-12s %s\n' "Component" "Pinned" "Latest" "Status"
  for r in "${rows[@]}"; do IFS='|' read -r n p l s _ <<<"$r"; printf '%-11s %-12s %-12s %s\n' "$n" "$p" "$l" "$s"; done
fi

if [[ "$MODE" == --strict && "$outdated" -gt 0 ]]; then exit 10; fi
exit 0

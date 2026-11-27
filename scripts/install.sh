#!/usr/bin/env bash
# Install prerequisites on Debian/Ubuntu: Docker Engine, Ansible, linters
# and (optionally) Terraform.
#
#   INSTALL_TERRAFORM=0   skip Terraform (the hashicorp/terraform container
#                         is used automatically instead)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

INSTALL_TERRAFORM="${INSTALL_TERRAFORM:-1}"

banner "Gitea Lab Installer"

[[ $EUID -ne 0 ]] || die "Do not run as root. Use a normal user with sudo access."
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Unsupported OS '${ID:-unknown}'. Install docker, make, curl, openssl manually." ;;
esac
have apt-get || die "apt-get not found"

KEYRINGS=/etc/apt/keyrings
ARCH="$(dpkg --print-architecture)"

section "Base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  ca-certificates curl gnupg git make jq openssl \
  ansible shellcheck yamllint
sudo install -m 0755 -d "$KEYRINGS"
pass "base packages"

section "Docker Engine"
if have docker; then
  pass "docker $(docker --version | awk '{print $3}' | tr -d ,) already installed"
else
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | sudo gpg --dearmor --yes -o "$KEYRINGS/docker.gpg"
  echo "deb [arch=${ARCH} signed-by=${KEYRINGS}/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io
  pass "docker installed"
fi
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
  warn "Added $USER to the docker group. Log out and back in (or run: newgrp docker)."
fi

section "Terraform"
if [[ "$INSTALL_TERRAFORM" != 1 ]]; then
  info "Skipped (INSTALL_TERRAFORM=0); the Terraform container will be used"
elif have terraform; then
  pass "terraform $(terraform version | head -1 | awk '{print $2}') already installed"
else
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o "$KEYRINGS/hashicorp.gpg"
  echo "deb [arch=${ARCH} signed-by=${KEYRINGS}/hashicorp.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq terraform
  pass "terraform installed"
fi

echo ""
echo "Install complete. Next: make bootstrap"

# ==========================================================
# Gitea Lab: Gitea + PostgreSQL on Docker, built by Terraform
#   make help    list targets
#   make build   bootstrap → validate → terraform apply → admin → health
# ==========================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

ENV_FILE := .env
TF       := ./scripts/tf.sh

# Terraform runner: auto (local if installed, else container) | local | docker
export TF_MODE ?= auto

# Container names come from LAB_NAME in .env (must match terraform/main.tf).
LAB_NAME := $(or $(shell sed -n 's/^LAB_NAME=//p' $(ENV_FILE) 2>/dev/null),gitea-lab)
GITEA    := $(LAB_NAME)-gitea
DB       := $(LAB_NAME)-db

# logs: which service (gitea|db). restore/smoke: BACKUP=<dir|latest>, FORCE=1
SERVICE ?= gitea
BACKUP  ?=
FORCE   ?= 0
SNAPSHOT ?= latest

export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
ANSIBLE_ARGS ?=

.PHONY: help install bootstrap validate lint build \
	init plan up apply down restart status logs shell db-shell update nuke \
	admin health diag check-updates smoke backup restore schedule unschedule \
	offsite offsite-snapshots offsite-check offsite-restore \
	tf-fmt tf-validate tf-output tf-state tf-version \
	ansible-ping ansible-check ansible-deploy

##@ Help

help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables: TF_MODE=auto|local|docker  SERVICE=gitea|db  BACKUP=<dir|latest>  FORCE=1"

##@ Setup

install: ## Install prerequisites (Debian/Ubuntu; INSTALL_TERRAFORM=0 to use the container)
	./scripts/install.sh

bootstrap: ## Create .env from .env.example and generate secrets (idempotent)
	./scripts/bootstrap.sh

validate: ## Validate scripts, YAML, Terraform and Ansible
	./scripts/validate.sh

lint: ## Like validate, but missing linters are failures (CI mode)
	STRICT=1 ./scripts/validate.sh

##@ Build (Terraform)

build: ## Everything: bootstrap, validate, terraform apply, admin user, health check
	@$(MAKE) bootstrap
	@$(MAKE) validate
	@$(MAKE) up
	@$(MAKE) admin
	@$(MAKE) health
	@echo ""
	@source ./scripts/lib.sh && load_env && echo "Gitea is up: $${GITEA_ROOT_URL}  (admin: $${GITEA_ADMIN_USER}, password in .env)"

init: ## terraform init (downloads the Docker provider)
	@$(TF) init -input=false </dev/null >/dev/null && echo "✓ terraform init ($(TF_MODE))"

plan: init ## Preview what Terraform would change
	$(TF) plan -input=false

up: init ## Create/update the lab (images, network, volumes, containers) and wait until healthy
	$(TF) apply -input=false -auto-approve

apply: init ## Like up, but shows the plan and asks first
	$(TF) apply -input=false

down: init ## Remove the containers; images, network and data volumes are kept
	$(TF) apply -input=false -auto-approve -var running=false

nuke: ## DANGER: destroy everything Terraform created, including data volumes
	@read -r -p "Delete the lab AND all Gitea data volumes? Type 'nuke' to confirm: " a && [[ "$$a" == nuke ]]
	@$(MAKE) init
	$(TF) destroy -input=false -auto-approve

update: ## Back up, then apply version changes from .env (e.g. GITEA_VERSION)
	@$(MAKE) backup
	@$(MAKE) up

##@ Operate

restart: ## Restart Gitea and the database
	docker restart $(DB) $(GITEA) >/dev/null
	@source ./scripts/lib.sh && wait_healthy $(GITEA) && echo "✓ $(GITEA) healthy"

status: ## Show the lab's containers
	@docker ps -a --filter label=lab.project=$(LAB_NAME) \
		--format 'table {{.Names}}\t{{.Status}}\t{{.Label "lab.image"}}\t{{.Ports}}'

logs: ## Follow logs (SERVICE=gitea|db)
	docker logs -f --tail=100 $(LAB_NAME)-$(SERVICE)

shell: ## Shell in the Gitea container as the git user
	docker exec -it -u git $(GITEA) bash

db-shell: ## psql in the database container
	@source ./scripts/lib.sh && require_env && docker exec -it $(DB) psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"

admin: ## Create the admin user from .env (idempotent)
	./scripts/create-admin.sh

##@ Health

health: ## Check containers, HTTP, SSH, Terraform drift, backups, disk
	./scripts/healthcheck.sh

diag: ## Show tool versions and which Terraform runner is used
	@for c in docker git make curl openssl ansible terraform shellcheck yamllint; do \
		if command -v $$c >/dev/null; then printf "%-11s %s\n" "$$c" "$$($$c --version 2>/dev/null | head -1)"; \
		else printf "%-11s %s\n" "$$c" "missing"; fi; \
	done
	@echo ""
	@if [[ "$(TF_MODE)" == docker ]] || { [[ "$(TF_MODE)" == auto ]] && ! command -v terraform >/dev/null; }; then \
		echo "Terraform runner: container hashicorp/terraform (TF_MODE=$(TF_MODE))"; \
	else \
		echo "Terraform runner: local $$(command -v terraform) (TF_MODE=$(TF_MODE))"; \
	fi

check-updates: ## Compare pinned image versions with the latest releases
	./scripts/check-updates.sh

smoke: ## DESTRUCTIVE end-to-end test: push, backup, delete, restore (needs FORCE=1)
	FORCE="$(FORCE)" ./scripts/smoke-test.sh

##@ Backup

backup: ## Back up database, repositories, .env, secrets and Terraform state (+ off-site if set)
	./scripts/backup.sh

restore: ## Restore: make restore BACKUP=backups/<stamp>|latest [FORCE=1]
	BACKUP="$(BACKUP)" FORCE="$(FORCE)" ./scripts/restore.sh

schedule: ## Run backups nightly via your crontab (BACKUP_SCHEDULE in .env)
	./scripts/schedule.sh install

unschedule: ## Remove the nightly backup from your crontab
	./scripts/schedule.sh remove

##@ Off-site (restic, encrypted; set RESTIC_REPOSITORY in .env)

offsite: ## Upload the newest local backup off-site and apply retention
	./scripts/offsite.sh push

offsite-snapshots: ## List off-site snapshots
	./scripts/offsite.sh snapshots

offsite-check: ## Verify the off-site repository's integrity
	./scripts/offsite.sh check

offsite-restore: ## Download an off-site snapshot into backups/ (SNAPSHOT=latest)
	./scripts/offsite.sh restore $(SNAPSHOT)

##@ Terraform extras

tf-fmt: ## Format Terraform files
	$(TF) fmt -recursive

tf-validate: init ## Validate Terraform configuration
	$(TF) validate

tf-output: ## Show Terraform outputs (URLs, container and volume names)
	$(TF) output

tf-state: ## List resources in Terraform state
	$(TF) state list

tf-version: ## Show the Terraform version in use
	$(TF) version

##@ Ansible

ansible-ping: ## Ping inventory hosts
	ansible all -m ping

ansible-check: ## Dry-run the deploy playbook (ANSIBLE_ARGS=-K for sudo password)
	ansible-playbook ansible/playbooks/deploy.yml --check --diff $(ANSIBLE_ARGS)

ansible-deploy: ## Deploy to inventory hosts (ANSIBLE_ARGS=-K for sudo password)
	ansible-playbook ansible/playbooks/deploy.yml $(ANSIBLE_ARGS)

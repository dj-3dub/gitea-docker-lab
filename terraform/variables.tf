# Every variable is fed from .env by scripts/tf.sh (see the mapping there),
# so .env stays the single place to configure the lab.

variable "lab_name" {
  description = "Prefix for containers, network and volumes (LAB_NAME)."
  type        = string
  default     = "gitea-lab"
}

variable "running" {
  description = "false removes the containers but keeps images, network and data volumes (make down)."
  type        = bool
  default     = true
}

# ---------- Images ----------
variable "gitea_version" {
  description = "Gitea image tag (GITEA_VERSION)."
  type        = string
  default     = "28.4.0"
}

variable "postgres_version" {
  description = "PostgreSQL image tag (POSTGRES_VERSION), starting with the major version, e.g. 19-alpine."
  type        = string
  default     = "19-alpine"

  validation {
    condition     = can(tonumber(split("-", var.postgres_version)[0]))
    error_message = "postgres_version must start with the major version number, e.g. 19-alpine or 19.1-alpine."
  }
}

# ---------- Gitea ----------
variable "user_uid" {
  description = "UID owning the Gitea data volume (USER_UID)."
  type        = number
  default     = 1000
}

variable "user_gid" {
  description = "GID owning the Gitea data volume (USER_GID)."
  type        = number
  default     = 1000
}

variable "timezone" {
  description = "Container time zone (TZ)."
  type        = string
  default     = "UTC"
}

variable "gitea_domain" {
  description = "Hostname Gitea advertises (GITEA_DOMAIN)."
  type        = string
  default     = "localhost"
}

variable "gitea_root_url" {
  description = "Public base URL of the web UI (GITEA_ROOT_URL)."
  type        = string
  default     = "http://localhost:3000/"
}

variable "gitea_ssh_domain" {
  description = "Hostname used in SSH clone URLs (GITEA_SSH_DOMAIN)."
  type        = string
  default     = "localhost"
}

variable "http_bind" {
  description = "Host address for the web port (GITEA_HTTP_BIND). 127.0.0.1 = this machine only."
  type        = string
  default     = "0.0.0.0"
}

variable "http_port" {
  description = "Host port for the web UI (GITEA_HTTP_PORT)."
  type        = number
  default     = 3000
}

variable "ssh_bind" {
  description = "Host address for the SSH port (GITEA_SSH_BIND)."
  type        = string
  default     = "0.0.0.0"
}

variable "ssh_port" {
  description = "Host port for Git over SSH (GITEA_SSH_PORT)."
  type        = number
  default     = 2222
}

variable "disable_registration" {
  description = "Disable self-registration (GITEA_DISABLE_REGISTRATION)."
  type        = bool
  default     = true
}

variable "require_signin_view" {
  description = "Require sign-in to view anything (GITEA_REQUIRE_SIGNIN_VIEW)."
  type        = bool
  default     = false
}

variable "log_level" {
  description = "Gitea log level (GITEA_LOG_LEVEL)."
  type        = string
  default     = "Info"
}

# ---------- PostgreSQL ----------
variable "postgres_db" {
  description = "Database name (POSTGRES_DB)."
  type        = string
  default     = "gitea"
}

variable "postgres_user" {
  description = "Database user (POSTGRES_USER)."
  type        = string
  default     = "gitea"
}

# ---------- Secrets ----------
# Secrets never pass through Terraform: they live in files that are
# bind-mounted read-only, so the state only ever contains this path.
variable "secrets_dir" {
  description = "Absolute host path holding postgres_password and gitea_secret_key (set by scripts/tf.sh)."
  type        = string

  validation {
    condition     = startswith(var.secrets_dir, "/")
    error_message = "secrets_dir must be an absolute path."
  }
}

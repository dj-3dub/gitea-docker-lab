locals {
  labels = {
    "lab.project" = var.lab_name
  }
  containers = var.running ? 1 : 0

  # Read-only secret mounts (see variable "secrets_dir").
  secret_db_password = "/run/secrets/postgres_password"
  secret_gitea_key   = "/run/secrets/gitea_secret_key"
}

# ----------------------------------------------------------
# Images, network and volumes are always kept, so `make down`
# (running = false) never touches data.
# ----------------------------------------------------------
resource "docker_image" "gitea" {
  name         = "docker.gitea.com/gitea:${var.gitea_version}"
  keep_locally = true
}

resource "docker_image" "postgres" {
  name         = "postgres:${var.postgres_version}"
  keep_locally = true
}

resource "docker_network" "lab" {
  name = "${var.lab_name}-net"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_volume" "gitea_data" {
  name = "${var.lab_name}-gitea-data"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_volume" "db_data" {
  name = "${var.lab_name}-db-data"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ----------------------------------------------------------
# PostgreSQL
# ----------------------------------------------------------
resource "docker_container" "db" {
  count = local.containers

  name    = "${var.lab_name}-db"
  image   = docker_image.postgres.image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=${var.postgres_db}",
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD_FILE=${local.secret_db_password}",
  ]

  volumes {
    volume_name    = docker_volume.db_data.name
    container_path = "/var/lib/postgresql/data"
  }

  volumes {
    host_path      = "${var.secrets_dir}/postgres_password"
    container_path = local.secret_db_password
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.lab.id
    aliases = ["db"]
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
    interval     = "5s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  # Terraform waits until the health check passes before Gitea is created.
  wait         = true
  wait_timeout = 120

  dynamic "labels" {
    for_each = merge(local.labels, { "lab.service" = "db", "lab.image" = docker_image.postgres.name })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ----------------------------------------------------------
# Gitea
# ----------------------------------------------------------
resource "docker_container" "gitea" {
  count = local.containers

  name    = "${var.lab_name}-gitea"
  image   = docker_image.gitea.image_id
  restart = "unless-stopped"

  env = [
    "USER_UID=${var.user_uid}",
    "USER_GID=${var.user_gid}",
    "TZ=${var.timezone}",
    "GITEA__database__DB_TYPE=postgres",
    "GITEA__database__HOST=db:5432",
    "GITEA__database__NAME=${var.postgres_db}",
    "GITEA__database__USER=${var.postgres_user}",
    "GITEA__database__PASSWD__FILE=${local.secret_db_password}",
    "GITEA__server__DOMAIN=${var.gitea_domain}",
    "GITEA__server__ROOT_URL=${var.gitea_root_url}",
    "GITEA__server__SSH_DOMAIN=${var.gitea_ssh_domain}",
    "GITEA__server__SSH_PORT=${var.ssh_port}",
    "GITEA__server__SSH_LISTEN_PORT=22",
    "GITEA__security__INSTALL_LOCK=true",
    "GITEA__security__SECRET_KEY__FILE=${local.secret_gitea_key}",
    "GITEA__service__DISABLE_REGISTRATION=${var.disable_registration}",
    "GITEA__service__REQUIRE_SIGNIN_VIEW=${var.require_signin_view}",
    "GITEA__log__LEVEL=${var.log_level}",
  ]

  ports {
    internal = 3000
    external = var.http_port
    ip       = var.http_bind
  }

  ports {
    internal = 22
    external = var.ssh_port
    ip       = var.ssh_bind
  }

  volumes {
    volume_name    = docker_volume.gitea_data.name
    container_path = "/data"
  }

  volumes {
    host_path      = "${var.secrets_dir}/postgres_password"
    container_path = local.secret_db_password
    read_only      = true
  }

  volumes {
    host_path      = "${var.secrets_dir}/gitea_secret_key"
    container_path = local.secret_gitea_key
    read_only      = true
  }

  networks_advanced {
    name = docker_network.lab.id
  }

  healthcheck {
    test         = ["CMD", "curl", "-fsS", "http://localhost:3000/api/healthz"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "20s"
  }

  wait         = true
  wait_timeout = 180

  dynamic "labels" {
    for_each = merge(local.labels, { "lab.service" = "gitea", "lab.image" = docker_image.gitea.name })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.db]
}

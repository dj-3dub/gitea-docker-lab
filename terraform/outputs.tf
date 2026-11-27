output "gitea_url" {
  description = "Gitea web UI."
  value       = var.gitea_root_url
}

output "ssh_clone_prefix" {
  description = "Prefix for SSH clone URLs."
  value       = "ssh://git@${var.gitea_ssh_domain}:${var.ssh_port}/"
}

output "containers" {
  description = "Container names (empty when running = false)."
  value = {
    gitea = one(docker_container.gitea[*].name)
    db    = one(docker_container.db[*].name)
  }
}

output "volumes" {
  description = "Data volumes. Kept by `make down`, removed by `make nuke`."
  value = {
    gitea_data = docker_volume.gitea_data.name
    db_data    = docker_volume.db_data.name
  }
}

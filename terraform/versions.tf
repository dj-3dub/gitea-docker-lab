terraform {
  required_version = ">= 1.6.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# Talks to the local Docker engine (DOCKER_HOST if set, else the
# default socket). scripts/tf.sh mounts the socket when Terraform
# runs in its container.
provider "docker" {}

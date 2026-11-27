# Architecture

```text
                      make up / make build
                              │
                              ▼
                     scripts/tf.sh ── reads .env → TF_VAR_*
                       │         │
            local terraform   hashicorp/terraform container
                       │         │  (docker.sock mounted, runs as your UID)
                       └────┬────┘
                            ▼
                terraform/ (kreuzwerker/docker) ── state: terraform/terraform.tfstate
                            │
 ┌──────────────────────── Docker host ─────────────────────────────┐
 │                                                                  │
 │   network: gitea-lab-net                                         │
 │                                                                  │
 │   ┌──────────────────┐   db:5432   ┌──────────────────┐          │
 │   │ gitea-lab-gitea  │ ──────────▶ │  gitea-lab-db    │          │
 │   │ :3000 HTTP  ◀────┼── LAN       │  postgres        │          │
 │   │ :2222 SSH   ◀────┼── LAN       └────────┬─────────┘          │
 │   └────────┬─────────┘                      │                    │
 │            │                                │                    │
 │   volume: gitea-lab-gitea-data     volume: gitea-lab-db-data     │
 └──────────────────────────────────────────────────────────────────┘
```

## Terraform resources (`terraform/main.tf`)

| Resource | Kept by `make down` | Notes |
|---|---|---|
| `docker_image.gitea`, `docker_image.postgres` | yes | `keep_locally = true`. Changing the tag in `.env` pulls the new image and replaces the container |
| `docker_network.lab` | yes | `<LAB_NAME>-net`. The database is reachable as `db` |
| `docker_volume.gitea_data`, `docker_volume.db_data` | yes | Only `make nuke` (`terraform destroy`) removes them |
| `docker_container.db` | no | `wait = true`: Terraform blocks until `pg_isready` passes |
| `docker_container.gitea` | no | Created after the database is healthy. Waits for `/api/healthz` |

The containers use `count = var.running ? 1 : 0`. `make down` sets `running = false`, so they are removed in a normal `apply`, without targeted destroys, and the data stays.

Every resource has the label `lab.project=<LAB_NAME>`, which `make status` filters on.

## Configuration flow

```text
.env.example ──make bootstrap──▶ .env (secrets generated, mode 600)
                                   │
                                   ├─▶ scripts/tf.sh ─▶ TF_VAR_* ─▶ terraform/variables.tf
                                   └─▶ backup / restore / health / admin scripts
```

Each `.env` key maps to one Terraform variable. The full mapping is at the top of `scripts/tf.sh`. Terraform state contains the container environment, including the database password and secret key, so it is gitignored, kept at mode `600`, and included in every backup.

## Why Terraform and not Compose?

Compose would work fine for one host. Using Terraform here means:

- `make plan` shows exactly what a version bump or config change will do before it happens.
- `make health` detects **drift**: a container changed or removed by hand shows up as a difference against the code.
- The same workflow extends to other Terraform providers (DNS, a reverse proxy, cloud VMs) in later projects.

## Gitea configuration

Gitea is configured entirely through `GITEA__section__KEY` environment variables. Nothing is edited in `app.ini` by hand. `INSTALL_LOCK=true` skips the web installer, and `make admin` creates the first admin from `.env`.

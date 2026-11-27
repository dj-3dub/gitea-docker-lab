# Backup and restore

![make backup](screenshots/terminal-make-backup.png)

## What is backed up

Each run of `make backup` creates `backups/<YYYYMMDD-HHMMSS>/` (mode `700`) containing:

| File | Contents |
|---|---|
| `db.dump` | `pg_dump -Fc` of the Gitea database (users, issues, PRs, settings) |
| `gitea-data.tar.gz` | The whole `/data` volume: bare repositories, LFS, attachments, avatars, `app.ini`, SSH host keys |
| `env.backup` | `.env`, including all secrets |
| `terraform.tfstate` | Terraform state for the lab |
| `manifest.txt` | Timestamp, host, image versions |
| `SHA256SUMS` | Checksums, verified before any restore |

Backups are written to `<stamp>.partial` first and renamed only when complete, so a failed run never leaves a half-finished backup. Only the newest `BACKUP_KEEP` backups (default 7) are kept.

**Consistency:** by default (`BACKUP_STOP_GITEA=1`) Gitea stops for the few seconds the backup takes, so the database and repositories match exactly. In testing, a hot backup taken right after a push recorded that repository as *empty* in the database. Gitea updates that flag in the background. Set `BACKUP_STOP_GITEA=0` only if you can't accept the brief downtime.

## Schedule it

```cron
# crontab -e on the Docker host
30 3 * * * cd /opt/gitea-lab && make backup >> backups/backup.log 2>&1
```

Copy `backups/` off the host (rsync, restic, rclone…). A backup kept only on the same disk won't survive losing that disk. The archives contain secrets, so encrypt them wherever they end up.

## Restore

```bash
make restore                                   # list backups
make restore BACKUP=backups/20261127-031500    # asks for confirmation
make restore BACKUP=latest FORCE=1             # no prompt
```

What happens, in order:

1. Checksums are verified. Any mismatch aborts the restore.
2. If the backup's `GITEA_SECRET_KEY` differs from `.env`, it is copied into `.env`. Gitea encrypts 2FA secrets and other data with that key. The previous `.env` is saved as `.env.pre-restore`.
3. Gitea is stopped, and the database is dropped and recreated from `db.dump`.
4. The data volume is emptied and extracted from `gitea-data.tar.gz`.
5. Gitea starts again, and the restore waits for it to report healthy. If the secret key changed in step 2, Terraform recreates the container with the new key.

`POSTGRES_PASSWORD` is not changed by a restore. The database is recreated inside the existing PostgreSQL volume, which keeps its password. The lab must be up (`make up`) before you restore.

### Restoring onto a new host

1. Clone the repo, then run `make install` and `make bootstrap`.
2. Copy the backup directory into `backups/`.
3. `make up` (Terraform creates an empty lab), then `make restore BACKUP=backups/<stamp>`.

The backup's `terraform.tfstate` belongs to the old host, so leave it there. The new host gets its own state from step 3.

## Testing restores

`FORCE=1 make smoke` pushes a repo, backs up, deletes the repo, restores and checks that the commit is back. CI runs it on every push. Run it locally only on a throwaway lab: it performs a real restore.

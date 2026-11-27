# Backup and restore

![make backup](screenshots/terminal-make-backup.png)

## What is backed up

Each run of `make backup` creates `backups/<YYYYMMDD-HHMMSS>/` (mode `700`) containing:

| File | Contents |
|---|---|
| `db.dump` | `pg_dump -Fc` of the Gitea database (users, issues, PRs, settings) |
| `gitea-data.tar.gz` | The whole `/data` volume: bare repositories, LFS, attachments, avatars, `app.ini`, SSH host keys |
| `env.backup` | `.env` (settings and the admin password) |
| `secrets/` | `postgres_password`, `gitea_secret_key`, `restic_password` |
| `terraform.tfstate` | Terraform state for the lab |
| `manifest.txt` | Timestamp, host, image versions |
| `SHA256SUMS` | Checksums, verified before any restore |

Backups are written to `<stamp>.partial` first and renamed only when complete, so a failed run never leaves a half-finished backup. Only the newest `BACKUP_KEEP` backups (default 7) are kept.

**Consistency:** by default (`BACKUP_STOP_GITEA=1`) Gitea stops for the few seconds the backup takes, so the database and repositories match exactly. In testing, a hot backup taken right after a push recorded that repository as *empty* in the database. Gitea updates that flag in the background. Set `BACKUP_STOP_GITEA=0` only if you can't accept the brief downtime.

## Schedule it

```bash
make schedule        # adds one line to your crontab (no sudo); runs BACKUP_SCHEDULE, default 03:30 daily
make unschedule      # removes only that line
```

Output goes to `backups/backup.log`. `make health` warns when no schedule is installed or the newest backup is more than 48 hours old.

To get told when a backup fails, set `BACKUP_NOTIFY_URL` in `.env`. On any failure the script POSTs a one-line message there. That works with ntfy (`https://ntfy.sh/<topic>`), a Slack incoming webhook or healthchecks.io.

## Off-site copies (restic)

A backup on the same disk doesn't survive losing that disk. Set `RESTIC_REPOSITORY` in `.env`, and every `make backup` (including scheduled ones) also uploads an **encrypted, deduplicated** copy:

| Target | `RESTIC_REPOSITORY` | Credentials in `.env` |
|---|---|---|
| Local path / NAS mount | `/mnt/nas/gitea-backups` | none |
| S3 or S3-compatible | `s3:https://s3.amazonaws.com/bucket/gitea-lab` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Backblaze B2 | `b2:bucket:gitea-lab` | `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` |
| restic REST server | `rest:https://user:pass@host/gitea-lab` | in the URL |

restic runs in the `restic/restic` container, so there's nothing to install. The SFTP and rclone backends aren't available because that image doesn't include them. The repository is created on first upload. Retention is `OFFSITE_KEEP` (default: 7 daily, 4 weekly, 6 monthly).

> **Save `secrets/restic_password` somewhere other than this machine**, such as a password manager. The off-site copies are encrypted with it, and without it they can't be decrypted.

| Command | What it does |
|---|---|
| `make offsite` | Upload the newest local backup now |
| `make offsite-snapshots` | List what's stored off-site |
| `make offsite-check` | Verify the repository's integrity |
| `make offsite-restore [SNAPSHOT=id]` | Download a snapshot into `backups/` (then run `make restore`) |

## Restore

```bash
make restore                                   # list backups
make restore BACKUP=backups/20261127-031500    # asks for confirmation
make restore BACKUP=latest FORCE=1             # no prompt
```

What happens, in order:

1. Checksums are verified. Any mismatch aborts the restore.
2. If the backup's `secrets/gitea_secret_key` differs from the current one, it replaces it. Gitea encrypts 2FA secrets and tokens with that key. The previous key is saved as `secrets/gitea_secret_key.pre-restore`.
3. Gitea is stopped, and the database is dropped and recreated from `db.dump`.
4. The data volume is emptied and extracted from `gitea-data.tar.gz`.
5. Gitea starts again, reads the key from its mounted file, and the restore waits for it to report healthy.

`secrets/postgres_password` is not changed by a restore. The database is recreated inside the existing PostgreSQL volume, which keeps its password. The lab must be up (`make up`) before you restore.

### Disaster recovery: new machine, nothing left but the off-site copy

This exact sequence is tested: lab, local backups and `secrets/` all deleted, then recovered.

1. Clone the repo, then run `make install` and `make bootstrap`.
2. Put the saved restic password in `secrets/restic_password`, and set `RESTIC_REPOSITORY` (plus any credentials) in `.env`.
3. `make offsite-restore`: the newest backup lands in `backups/`.
4. Optional: `cp backups/<stamp>/env.backup .env` to get the old settings and admin password back.
5. `make up`, then `make restore BACKUP=latest`. The original `SECRET_KEY` is restored from the backup automatically.

The backup's `terraform.tfstate` belongs to the old host, so leave it there. The new host gets its own state from step 5.

## Testing restores

`FORCE=1 make smoke` pushes a repo, backs up, deletes the repo, restores and checks that the commit is back. CI runs it on every push. Run it locally only on a throwaway lab: it performs a real restore.

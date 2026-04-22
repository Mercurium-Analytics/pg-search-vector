# pg-search-vector-backup

Daily `pg_dump` → Cloudflare R2 (or any S3-compatible storage). Tiny Alpine sidecar, ~20 MB image.

## Required environment variables

| Var | Purpose | Example |
|---|---|---|
| `DB_HOST` | Postgres host (reach the DB container) | `db` |
| `DB_PORT` | Postgres port | `5432` |
| `DB_NAME` | Database to back up | `app` |
| `DB_USER` | DB user (superuser for full dump, or dedicated `backup` role) | `postgres` |
| `DB_PASSWORD` | DB password | *(secret)* |
| `R2_ENDPOINT_URL` | R2 S3 endpoint | `https://<account-id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` | R2 API token — access key | *(secret)* |
| `R2_SECRET_ACCESS_KEY` | R2 API token — secret key | *(secret)* |
| `R2_BUCKET` | Bucket to write to | `mercurium-backups` |

## Optional variables

| Var | Default | Purpose |
|---|---|---|
| `BACKUP_PREFIX` | `pg-search-vector` | Key prefix inside the bucket |
| `BACKUP_SCHEDULE` | `0 3 * * *` | Cron (UTC) |
| `BACKUP_RETENTION_DAYS` | `30` | Prune older backups |
| `BACKUP_ON_START` | `false` | Run one backup immediately on boot |

## Set up R2 credentials (one-time, Cloudflare dashboard)

1. **Cloudflare dashboard → R2 → Manage R2 API Tokens → Create API Token**
2. Permission: **Object Read & Write**
3. Specify bucket (or all buckets)
4. Copy:
   - Access Key ID → `R2_ACCESS_KEY_ID`
   - Secret Access Key → `R2_SECRET_ACCESS_KEY`
   - Endpoint → `R2_ENDPOINT_URL` (format: `https://<account-id>.r2.cloudflarestorage.com`)
5. **Create a dedicated bucket** for backups (don't reuse app storage):
   - Dashboard → R2 → Create Bucket → `<your-org>-db-backups` (e.g. `mercurium-analytics-db-backups`)
   - Region: Auto / nearest to your DB
   - Set lifecycle rule: delete objects >90 days (belt-and-braces alongside our `BACKUP_RETENTION_DAYS`)

## Usage

### docker-compose

```yaml
services:
  db:
    image: ghcr.io/mercurium-analytics/pg-search-vector:pg17-pooled
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_APP_PASSWORD: ${POSTGRES_APP_PASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
      - "6432:6432"

  backup:
    image: ghcr.io/mercurium-analytics/pg-search-vector-backup:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      DB_HOST: db
      DB_PORT: "5432"
      DB_NAME: ${POSTGRES_DB}
      DB_USER: postgres
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      R2_ENDPOINT_URL: ${R2_ENDPOINT_URL}
      R2_ACCESS_KEY_ID: ${R2_ACCESS_KEY_ID}
      R2_SECRET_ACCESS_KEY: ${R2_SECRET_ACCESS_KEY}
      R2_BUCKET: mercurium-db-backups
      BACKUP_SCHEDULE: "0 3 * * *"        # 03:00 UTC daily
      BACKUP_RETENTION_DAYS: "30"
      BACKUP_ON_START: "true"             # run one now so you know it works

volumes:
  pg_data:
```

### Railway

Add a second service from the backup image:

1. New Service → **"Deploy from Docker Image"** → `ghcr.io/mercurium-analytics/pg-search-vector-backup:latest`
2. Variables: copy the env vars above. Use Railway's **Shared Variables** + **"Reference Variable"** so `DB_PASSWORD` and `R2_*` stay in sync with the primary service.
3. `DB_HOST` = internal hostname of the DB service (Railway gives you `${{pg-search-vector.RAILWAY_PRIVATE_DOMAIN}}`)
4. No ports to expose — this service only connects outbound.

### Fly.io

A scheduled-machine app with the same env:

```toml
app = "mercurium-backups"
[build]
image = "ghcr.io/mercurium-analytics/pg-search-vector-backup:latest"
[env]
DB_HOST = "mercurium-db.internal"
# ... other env vars or set via `fly secrets`
```

Set secrets: `fly secrets set DB_PASSWORD=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=...`

## Restore

```bash
# List available backups
docker run --rm \
  -e R2_ENDPOINT_URL=... -e R2_ACCESS_KEY_ID=... -e R2_SECRET_ACCESS_KEY=... -e R2_BUCKET=... \
  ghcr.io/mercurium-analytics/pg-search-vector-backup:latest \
  pgsv-restore

# Restore the most recent
docker run --rm -it \
  -e DB_HOST=db -e DB_NAME=app -e DB_USER=postgres -e DB_PASSWORD=... \
  -e R2_ENDPOINT_URL=... -e R2_ACCESS_KEY_ID=... -e R2_SECRET_ACCESS_KEY=... -e R2_BUCKET=... \
  ghcr.io/mercurium-analytics/pg-search-vector-backup:latest \
  pgsv-restore latest

# Restore a specific key
pgsv-restore pg-search-vector/2026-04-20/pg-search-vector-20260420T030000Z.sqlc
```

## Monitoring

- Container exposes a healthcheck that fails if no successful backup in 36h.
- Log path inside container: `/var/log/pgsv-backup/cron.log` — mount to host / ship to your log aggregator if you want.
- Last success: `/var/log/pgsv-backup/last-success.stamp` (mtime = last successful backup).

## Cost

Cloudflare R2 pricing (2026):
- Storage: $0.015/GB/month
- Egress: **$0** (biggest advantage over S3)
- Class A operations (writes): $4.50/million
- Class B operations (reads): $0.36/million

For your 3 GB compressed backup × 30 retention = ~90 GB = **~$1.35/month storage**. Restore downloads: free.

## What this does NOT cover

- **Point-in-time recovery (PITR)**: `pg_dump` is a logical snapshot. You can restore to the backup's moment, not between moments. If that matters, add WAL-G on top (v0.4+).
- **Large DB performance**: `pg_dump` of a multi-TB DB takes hours. At that scale switch to `pg_basebackup` + WAL archiving.

For under ~500 GB DBs, this is the right tool.

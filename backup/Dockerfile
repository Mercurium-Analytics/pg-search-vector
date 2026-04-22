# pg-search-vector-backup: daily pg_dump → Cloudflare R2 (or any S3-compatible).
#
# Small Alpine sidecar with postgresql-client + awscli v2 + cron.
#
# Build:
#   docker build -t pg-search-vector-backup:latest pg-search-vector/backup/
#
# Run (requires env — see README):
#   docker run --rm -it \
#     -e DB_HOST=... -e DB_PORT=5432 -e DB_NAME=... -e DB_USER=... -e DB_PASSWORD=... \
#     -e R2_ACCESS_KEY_ID=... -e R2_SECRET_ACCESS_KEY=... \
#     -e R2_ENDPOINT_URL=https://<account>.r2.cloudflarestorage.com \
#     -e R2_BUCKET=my-backups \
#     -e BACKUP_RETENTION_DAYS=30 \
#     -e BACKUP_SCHEDULE="0 3 * * *" \
#     pg-search-vector-backup:latest

FROM alpine:3.20

LABEL org.opencontainers.image.title="pg-search-vector-backup"
LABEL org.opencontainers.image.description="Scheduled pg_dump to S3-compatible storage (Cloudflare R2, AWS S3, Backblaze B2)."

RUN apk add --no-cache \
      postgresql17-client \
      aws-cli \
      gzip \
      ca-certificates \
      tzdata \
      bash \
      dcron \
      coreutils \
 && mkdir -p /var/log/pgsv-backup /var/spool/cron/crontabs
# coreutils: GNU `stat -c%s`, `numfmt`, and `date -d` used by backup.sh.
# BusyBox's stat/date are not fully flag-compatible.

COPY backup.sh  /usr/local/bin/pgsv-backup
COPY restore.sh /usr/local/bin/pgsv-restore
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/pgsv-backup /usr/local/bin/pgsv-restore /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=1h --timeout=10s --retries=1 \
  CMD test -f /var/log/pgsv-backup/last-success.stamp \
   && test $(($(date +%s) - $(date +%s -r /var/log/pgsv-backup/last-success.stamp))) -lt 129600 \
   || exit 1
# Unhealthy if no successful backup in 36h (catches silent failures)

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

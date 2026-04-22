#!/bin/bash
# Daily backup: pg_dump → gzipped custom-format → S3-compatible (Cloudflare R2).
#
# Required env:
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
#   R2_ENDPOINT_URL          (e.g. https://<account-id>.r2.cloudflarestorage.com)
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_BUCKET                (target bucket for backups)
#
# Optional:
#   BACKUP_PREFIX            (default: pg-search-vector)
#   BACKUP_RETENTION_DAYS    (default: 30 — older backups pruned)

set -euo pipefail

: "${DB_HOST:?DB_HOST required}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?DB_NAME required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASSWORD:?DB_PASSWORD required}"
: "${R2_ENDPOINT_URL:?R2_ENDPOINT_URL required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required}"
: "${R2_BUCKET:?R2_BUCKET required}"

PREFIX="${BACKUP_PREFIX:-pg-search-vector}"
RETENTION="${BACKUP_RETENTION_DAYS:-30}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DAY=$(date -u +%Y-%m-%d)
FILE="${PREFIX}-${STAMP}.sqlc"
KEY="${PREFIX}/${DAY}/${FILE}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export PGPASSWORD="$DB_PASSWORD"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "pg_dump → R2 (${KEY})"
pg_dump \
  --host="$DB_HOST" --port="$DB_PORT" \
  --username="$DB_USER" --dbname="$DB_NAME" \
  --format=custom --compress=6 --no-owner --no-acl \
  --file=/tmp/backup.sqlc

SIZE=$(stat -c%s /tmp/backup.sqlc)
log "dumped $(numfmt --to=iec $SIZE) → uploading"

aws s3 cp /tmp/backup.sqlc "s3://${R2_BUCKET}/${KEY}" \
  --endpoint-url "$R2_ENDPOINT_URL" \
  --no-progress

rm /tmp/backup.sqlc

# Prune old backups beyond retention window
CUTOFF=$(date -u -d "${RETENTION} days ago" +%Y-%m-%d 2>/dev/null || \
         date -u -v-${RETENTION}d +%Y-%m-%d)
log "pruning backups older than ${CUTOFF}"

aws s3 ls "s3://${R2_BUCKET}/${PREFIX}/" \
  --endpoint-url "$R2_ENDPOINT_URL" \
  --recursive 2>/dev/null \
  | awk -v cutoff="$CUTOFF" '$1 < cutoff {print $4}' \
  | while read -r old_key; do
      [ -z "$old_key" ] && continue
      log "  deleting s3://${R2_BUCKET}/${old_key}"
      aws s3 rm "s3://${R2_BUCKET}/${old_key}" --endpoint-url "$R2_ENDPOINT_URL"
    done

touch /var/log/pgsv-backup/last-success.stamp
log "done (key: ${KEY})"

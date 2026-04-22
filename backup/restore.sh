#!/bin/bash
# Restore from R2 into a target Postgres.
#
# Usage:
#   pgsv-restore                      # list available backups
#   pgsv-restore <s3-key>             # restore specific backup
#   pgsv-restore latest               # restore the most recent backup
#
# Env same as backup.sh plus the target DB to restore INTO (can be different
# from the DB that was backed up — set DB_HOST/DB_NAME to target).

set -euo pipefail

: "${R2_ENDPOINT_URL:?R2_ENDPOINT_URL required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required}"
: "${R2_BUCKET:?R2_BUCKET required}"

PREFIX="${BACKUP_PREFIX:-pg-search-vector}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"

ARG="${1:-}"

if [ -z "$ARG" ]; then
  echo "Available backups in s3://${R2_BUCKET}/${PREFIX}/ :"
  aws s3 ls "s3://${R2_BUCKET}/${PREFIX}/" \
    --endpoint-url "$R2_ENDPOINT_URL" --recursive \
    | sort | tail -30
  echo
  echo "Restore: pgsv-restore <key>   (or 'latest')"
  exit 0
fi

if [ "$ARG" = "latest" ]; then
  KEY=$(aws s3 ls "s3://${R2_BUCKET}/${PREFIX}/" \
          --endpoint-url "$R2_ENDPOINT_URL" --recursive \
        | sort | tail -1 | awk '{print $4}')
else
  KEY="$ARG"
fi

: "${DB_HOST:?DB_HOST required}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?DB_NAME required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASSWORD:?DB_PASSWORD required}"
export PGPASSWORD="$DB_PASSWORD"

echo "restoring s3://${R2_BUCKET}/${KEY} into ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
read -p "confirm? (yes/NO) " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "aborted"; exit 1; }

aws s3 cp "s3://${R2_BUCKET}/${KEY}" /tmp/restore.sqlc \
  --endpoint-url "$R2_ENDPOINT_URL" --no-progress

pg_restore \
  --host="$DB_HOST" --port="$DB_PORT" \
  --username="$DB_USER" --dbname="$DB_NAME" \
  --no-owner --no-acl -j 4 /tmp/restore.sqlc

rm /tmp/restore.sqlc
echo "restored."

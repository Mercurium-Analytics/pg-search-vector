#!/bin/bash
# WAL-G restore. Recovers Postgres to a specific point in time (PITR).
#
# DANGEROUS: this destroys the current $PGDATA and fetches a base backup from
# object storage. Only run against an EMPTY volume or one you're willing to
# overwrite.
#
# Usage:
#   1. Stop the running Postgres service.
#   2. Wipe or attach a fresh volume at /var/lib/postgresql/data.
#   3. Set env vars for your R2/S3 target (see below).
#   4. Run this script.
#   5. Start Postgres — it will replay WAL up to the recovery target.
#
# Env:
#   WALG_S3_PREFIX, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT, AWS_REGION
#   BACKUP_NAME           — 'LATEST' (default) or a specific backup name
#   RECOVERY_TARGET_TIME  — optional, e.g. '2026-04-21 14:30:00 UTC'
#   RECOVERY_TARGET_NAME  — optional, e.g. 'before-bad-migration'

set -e

: "${WALG_S3_PREFIX:?required}"
: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"

BACKUP_NAME="${BACKUP_NAME:-LATEST}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

export WALG_S3_PREFIX AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_ENDPOINT="${AWS_ENDPOINT:-}"
export AWS_REGION="${AWS_REGION:-auto}"
export AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-true}"

echo "--- Listing available backups ---"
/usr/local/bin/wal-g backup-list

echo
echo "--- Fetching base backup: $BACKUP_NAME → $PGDATA ---"
if [ -d "$PGDATA" ] && [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "ABORT: $PGDATA is not empty. Refusing to overwrite." >&2
  echo "Wipe it first (e.g. rm -rf $PGDATA/*) if you really mean it." >&2
  exit 1
fi

mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

su postgres -c "/usr/local/bin/wal-g backup-fetch $PGDATA $BACKUP_NAME"

echo
echo "--- Writing recovery.signal + restore_command ---"
touch "$PGDATA/recovery.signal"

# Add WAL-G as the restore_command so Postgres fetches WAL segments on startup
cat >> "$PGDATA/postgresql.auto.conf" <<EOF

# Added by wal-g-restore.sh
restore_command = '/usr/local/bin/wal-g wal-fetch "%f" "%p"'
EOF

if [ -n "$RECOVERY_TARGET_TIME" ]; then
  echo "recovery_target_time = '$RECOVERY_TARGET_TIME'" >> "$PGDATA/postgresql.auto.conf"
  echo "recovery_target_action = 'promote'"               >> "$PGDATA/postgresql.auto.conf"
  echo "Recovery target: time '$RECOVERY_TARGET_TIME'"
elif [ -n "$RECOVERY_TARGET_NAME" ]; then
  echo "recovery_target_name = '$RECOVERY_TARGET_NAME'"   >> "$PGDATA/postgresql.auto.conf"
  echo "recovery_target_action = 'promote'"               >> "$PGDATA/postgresql.auto.conf"
  echo "Recovery target: restore point '$RECOVERY_TARGET_NAME'"
else
  echo "No recovery target set → will replay ALL available WAL to end of archive."
fi

chown postgres:postgres "$PGDATA/postgresql.auto.conf" "$PGDATA/recovery.signal"

echo
echo "--- Done preparing \$PGDATA ---"
echo "Start Postgres normally (docker-compose up -d db). It will:"
echo "  1. See recovery.signal and enter archive recovery"
echo "  2. Fetch WAL segments from $WALG_S3_PREFIX via wal-g wal-fetch"
echo "  3. Replay WAL up to the target (or end of archive)"
echo "  4. Promote itself to normal operation"
echo
echo "Watch: tail -f $PGDATA/../logs or the container logs."

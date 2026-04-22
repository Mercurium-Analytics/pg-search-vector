#!/bin/bash
# Run a WAL-G base backup. Call periodically (weekly recommended) via pg_cron,
# or from a Railway/Fly scheduled job, or from manual ops.
#
# Usage inside the container:
#   su postgres -c /usr/local/bin/wal-g-basebackup.sh
#
# Or from outside:
#   docker exec db-container su postgres -c /usr/local/bin/wal-g-basebackup.sh

set -e

if [ ! -f /etc/wal-g/wal-g.env ]; then
  echo "wal-g-basebackup: WAL-G not configured; set WALG_S3_PREFIX + AWS_* env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source /etc/wal-g/wal-g.env
set +a

echo "[$(date -u +%H:%M:%S)] starting wal-g backup-push"
/usr/local/bin/wal-g backup-push "${PGDATA:-/var/lib/postgresql/data}"
echo "[$(date -u +%H:%M:%S)] backup-push done"

echo "--- recent backups ---"
/usr/local/bin/wal-g backup-list | tail -20

# Delete backups older than retention (default: keep last 4 base backups + their WAL)
RETAIN_FULL="${WALG_RETAIN_FULL_BACKUPS:-4}"
echo "--- pruning backups beyond $RETAIN_FULL ---"
/usr/local/bin/wal-g delete retain FULL "$RETAIN_FULL" --confirm || true

#!/bin/bash
# Wrapper invoked by Postgres as archive_command.
#
# Postgres passes: $1 = full path to WAL file, $2 = WAL file name
# Environment: wal-g reads /etc/wal-g/wal-g.env
#
# Exits 0 on success, non-zero on failure. Postgres retries failed archives
# automatically — if this returns non-zero repeatedly, WAL piles up in pg_wal.

set -e

if [ ! -f /etc/wal-g/wal-g.env ]; then
  # Shouldn't happen if bootstrap ran, but be safe
  echo "wal-g-archive: /etc/wal-g/wal-g.env missing" >&2
  exit 1
fi

# Load wal-g config (keys are exported to wal-g subprocess)
set -a
# shellcheck disable=SC1091
source /etc/wal-g/wal-g.env
set +a

exec /usr/local/bin/wal-g wal-push "$1"

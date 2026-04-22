#!/bin/bash
# Opt into WAL-G on an already-running cluster.
#
# The first-boot init (`/docker-entrypoint-initdb.d/30-walg-bootstrap.sh`) only
# fires on a fresh volume. If your DB is already running and you now want WAL-G,
# run this script inside the container, then restart Postgres so archive_mode
# takes effect.
#
# Usage:
#   docker exec -e WALG_S3_PREFIX=... -e AWS_ACCESS_KEY_ID=... \
#               -e AWS_SECRET_ACCESS_KEY=... -e AWS_ENDPOINT=... \
#               <container> bash /usr/local/bin/pgsv-walg-enable.sh
#
# Then restart Postgres:
#   docker restart <container>
#
# OR, from inside the container as root:
#   su postgres -c "pg_ctl restart -D \$PGDATA -m fast"
#
# After the restart, pg_cron runs the initial base backup within 60s.

set -euo pipefail

: "${WALG_S3_PREFIX:?set WALG_S3_PREFIX before running}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID before running}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY before running}"

# Sanity: Postgres must be up so we can schedule cron jobs.
if ! pg_isready -h /var/run/postgresql -U "${POSTGRES_USER:-postgres}" -q 2>/dev/null; then
  echo "pgsv-walg-enable: Postgres isn't accepting connections on /var/run/postgresql." >&2
  echo "  This script must run inside a running container." >&2
  exit 1
fi

echo "=== configuring WAL-G ==="
/usr/local/bin/pgsv-walg-configure.sh

cat <<'MSG'

=== NEXT STEP: restart Postgres ===

  archive_mode = on requires a FULL POSTGRES RESTART.
  A reload (pg_reload_conf / SIGHUP) is NOT enough.

  From outside the container:
    docker restart <container-name>

  From inside, as root:
    su postgres -c "pg_ctl restart -D $PGDATA -m fast"

After the restart, pg_cron runs the initial basebackup within a minute and
then unschedules itself. Tail the log:

    tail -f /var/log/postgresql/wal-g.log

MSG

#!/bin/bash
# Configure WAL-G continuous archiving + pg_cron backup schedule.
#
# Idempotent: safe to re-run. Writes:
#   /etc/wal-g/wal-g.env                         — credentials (mode 600)
#   /etc/postgresql/conf.d/40-walg-archive.conf  — archive_mode + archive_command
#   /var/log/postgresql/wal-g.log                — backup/archive log destination
#   cron.job rows                                 — initial + weekly basebackups
#
# Reads env:
#   WALG_S3_PREFIX              (required)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_ENDPOINT, AWS_REGION, AWS_S3_FORCE_PATH_STYLE
#   WALG_COMPRESSION_METHOD, WALG_DELTA_MAX_STEPS
#   POSTGRES_USER (default: postgres), POSTGRES_DB (default: postgres)
#   PGSV_WALG_WEEKLY_SCHEDULE   (default: '0 4 * * 0', Sunday 04:00 UTC)
#
# Called from:
#   init/30-walg-bootstrap.sh    (first-boot; volume init)
#   bin/pgsv-walg-enable.sh      (opt-in on running cluster)

set -euo pipefail

: "${WALG_S3_PREFIX:?WALG_S3_PREFIX required}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"

# 1) wal-g credentials file
mkdir -p /etc/wal-g
cat > /etc/wal-g/wal-g.env <<EOF
WALG_S3_PREFIX=${WALG_S3_PREFIX}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
AWS_ENDPOINT=${AWS_ENDPOINT:-}
AWS_REGION=${AWS_REGION:-auto}
AWS_S3_FORCE_PATH_STYLE=${AWS_S3_FORCE_PATH_STYLE:-true}
WALG_COMPRESSION_METHOD=${WALG_COMPRESSION_METHOD:-lz4}
WALG_DELTA_MAX_STEPS=${WALG_DELTA_MAX_STEPS:-0}
PGHOST=/var/run/postgresql
PGUSER=${POSTGRES_USER}
PGDATABASE=${POSTGRES_DB}
EOF
chmod 600 /etc/wal-g/wal-g.env
chown postgres:postgres /etc/wal-g/wal-g.env

# 2) archive_mode + archive_command
mkdir -p /etc/postgresql/conf.d
cat > /etc/postgresql/conf.d/40-walg-archive.conf <<'EOF'
# Written by pgsv-walg-configure.sh. archive_mode change requires a restart;
# after changing this file, restart Postgres (SIGINT + cold start) — a reload
# is NOT sufficient.
wal_level        = replica
archive_mode     = on
archive_timeout  = 60
archive_command  = '/usr/local/bin/wal-g-archive.sh %p %f'
max_wal_senders  = 3
EOF

# 3) log destination
mkdir -p /var/log/postgresql
touch /var/log/postgresql/wal-g.log
chown postgres:postgres /var/log/postgresql/wal-g.log

# 4) pg_cron schedule — weekly backup + one-shot initial that unschedules itself
WEEKLY="${PGSV_WALG_WEEKLY_SCHEDULE:-0 4 * * 0}"

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname postgres \
     -v weekly="$WEEKLY" <<'EOSQL'
-- Idempotent: wipe previous schedule entries so edits to PGSV_WALG_WEEKLY_SCHEDULE
-- actually take effect. SELECT-with-WHERE-from-cron.job yields zero rows if the
-- job doesn't exist, so this is safe even on a fresh init.
SELECT cron.unschedule(jobid)
  FROM cron.job
 WHERE jobname IN ('pgsv_walg_weekly_basebackup', 'pgsv_walg_initial_basebackup');

-- Weekly full backup.
SELECT cron.schedule(
  'pgsv_walg_weekly_basebackup',
  :'weekly',
  $$COPY (SELECT 1) TO PROGRAM '/usr/local/bin/wal-g-basebackup.sh >> /var/log/postgresql/wal-g.log 2>&1'$$
);

-- One-shot initial backup.  Runs every minute until it succeeds; on success
-- the DO block calls cron.unschedule() to clear itself. If the backup fails
-- (bad creds, bucket ACL, network), COPY raises and the unschedule is never
-- reached — so the job retries next minute until the operator fixes the env.
SELECT cron.schedule(
  'pgsv_walg_initial_basebackup',
  '* * * * *',
  $job$DO $do$ BEGIN
    COPY (SELECT 1) TO PROGRAM
      '/usr/local/bin/wal-g-basebackup.sh >> /var/log/postgresql/wal-g.log 2>&1';
    PERFORM cron.unschedule('pgsv_walg_initial_basebackup');
  END $do$;$job$
);
EOSQL

echo "pgsv-walg-configure: done."
echo "  weekly schedule  = ${WEEKLY}"
echo "  initial backup   = next pg_cron tick after postgres reload (1–60s)"
echo "  log              = /var/log/postgresql/wal-g.log"

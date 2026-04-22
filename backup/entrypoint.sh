#!/bin/bash
# Launch cron with the desired schedule, forwarding container env to the job.
# Default: daily at 03:00 UTC. Override via BACKUP_SCHEDULE (cron format).
set -e

SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"

# Persist env vars so the cron job sees them (cron strips env by default).
# dcron invokes /bin/sh (busybox), so we escape with POSIX-portable single
# quoting (bash's printf %q emits $'…' for special chars, which busybox sh
# can't parse). Naive `env | grep` would break on passwords containing
# spaces/quotes/$, and a crafted value could execute arbitrary commands.
: > /etc/backup.env
chmod 600 /etc/backup.env
while IFS='=' read -r name value; do
  case "$name" in
    DB_*|R2_*|BACKUP_*|PG*) ;;
    *) continue ;;
  esac
  # Wrap value in single quotes; escape embedded single quotes as '\''.
  escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
  printf "export %s='%s'\n" "$name" "$escaped" >> /etc/backup.env
done < <(env)

cat > /etc/crontabs/root <<EOF
${SCHEDULE} . /etc/backup.env && /usr/local/bin/pgsv-backup >> /var/log/pgsv-backup/cron.log 2>&1
EOF

echo "pg-search-vector-backup: schedule = '${SCHEDULE}' (UTC)"

# Run one backup immediately so the first test isn't 24h away
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  echo "pg-search-vector-backup: running initial backup now (BACKUP_ON_START=true)"
  /usr/local/bin/pgsv-backup || echo "initial backup failed — cron will retry"
fi

exec crond -f -l 8

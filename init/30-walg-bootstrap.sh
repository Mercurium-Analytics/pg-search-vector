#!/bin/bash
# WAL-G bootstrap — runs once on fresh volume via /docker-entrypoint-initdb.d.
#
# Activates ONLY when WALG_S3_PREFIX is set. Otherwise this is a no-op —
# the image works out-of-the-box without backups, and you opt in by setting
# env vars in your platform (Railway / Fly / compose).
#
# The heavy lifting (env file, archive conf, pg_cron schedule) lives in
# /usr/local/bin/pgsv-walg-configure.sh so the opt-in-on-running-cluster
# path (bin/pgsv-walg-enable.sh) reuses exactly the same logic.
#
# Required env vars to enable:
#   WALG_S3_PREFIX              s3://your-bucket/walg
#   AWS_ACCESS_KEY_ID           your R2 / S3 access key
#   AWS_SECRET_ACCESS_KEY       your R2 / S3 secret key
#   AWS_ENDPOINT                https://<account>.r2.cloudflarestorage.com  (R2)
#   AWS_REGION                  auto (R2) or us-east-1 etc for S3
#   AWS_S3_FORCE_PATH_STYLE     true (for R2)
#
# Optional:
#   WALG_COMPRESSION_METHOD     lz4 (default) | zstd | brotli
#   WALG_DELTA_MAX_STEPS        0 (default) — chain of delta backups before new full
#   PGSV_WALG_WEEKLY_SCHEDULE   '0 4 * * 0' (default) — cron expression for weekly

set -e

if [ -z "${WALG_S3_PREFIX:-}" ]; then
  echo "pg-search-vector: WALG_S3_PREFIX not set — continuous archiving DISABLED."
  echo "pg-search-vector: set WALG_S3_PREFIX + AWS_* env vars to enable PITR."
  exit 0
fi

echo "pg-search-vector: enabling WAL-G continuous archiving → $WALG_S3_PREFIX"

/usr/local/bin/pgsv-walg-configure.sh

echo ""
echo "  Initial base backup will run via pg_cron on the FINAL postgres start"
echo "  (i.e. after this init mode exits and archive_mode=on takes effect)."
echo "  The job auto-unschedules after the first successful backup; retries"
echo "  every minute if it fails. Tail /var/log/postgresql/wal-g.log to watch."

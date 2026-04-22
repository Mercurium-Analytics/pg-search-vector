#!/bin/bash
# Bootstrap pgsv on container init.
# The postgres image runs anything in /docker-entrypoint-initdb.d on first
# volume init. We use the $POSTGRES_DB target so helpers are installed there.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
  CREATE EXTENSION IF NOT EXISTS pg_search;
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  CREATE EXTENSION IF NOT EXISTS pg_repack;
  CREATE EXTENSION IF NOT EXISTS pg_prewarm;
  CREATE EXTENSION IF NOT EXISTS pg_wait_sampling;
  CREATE EXTENSION IF NOT EXISTS pgaudit;
  CREATE SCHEMA IF NOT EXISTS partman;
  CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;
EOSQL

# pg_cron metadata lives in the 'postgres' database (or whatever cron.database_name
# points to) — not the app DB. Install the extension there.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  GRANT USAGE ON SCHEMA cron TO "$POSTGRES_USER";
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -f /usr/local/share/pgsv/pgsv.sql

echo "pgsv bootstrap complete."

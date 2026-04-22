#!/bin/bash
# Create a non-superuser application role.
#
# Use this role in your app's DB connection. Keep the superuser (postgres) for
# migrations and maintenance only. Substantially reduces blast radius of app
# SQL injection or accidental DROP.
#
# Env:
#   POSTGRES_APP_USER      (default: app)
#   POSTGRES_APP_PASSWORD  (required; if unset, this step is skipped with a warning)

set -e

APP_USER="${POSTGRES_APP_USER:-app}"

if [ -z "$POSTGRES_APP_PASSWORD" ]; then
  echo "pg-search-vector: POSTGRES_APP_PASSWORD not set — skipping non-superuser role creation."
  echo "pg-search-vector: You will connect as the superuser. NOT recommended for production."
  exit 0
fi

APP_STATEMENT_TIMEOUT="${POSTGRES_APP_STATEMENT_TIMEOUT:-30s}"
APP_LOCK_TIMEOUT="${POSTGRES_APP_LOCK_TIMEOUT:-5s}"
APP_IDLE_TX_TIMEOUT="${POSTGRES_APP_IDLE_IN_TRANSACTION_SESSION_TIMEOUT:-60s}"

# Pass the password through psql -v so quoting is handled by psql (handles
# apostrophes, dollar signs, backslashes etc.); shell interpolation into a
# heredoc'd SQL literal would break on any of those.
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_user="$APP_USER" \
     -v app_password="$POSTGRES_APP_PASSWORD" \
     -v app_database="$POSTGRES_DB" \
     -v app_statement_timeout="$APP_STATEMENT_TIMEOUT" \
     -v app_lock_timeout="$APP_LOCK_TIMEOUT" \
     -v app_idle_tx_timeout="$APP_IDLE_TX_TIMEOUT" <<'EOSQL'
  -- :"var" quotes as identifier, :'var' quotes as SQL literal. Passwords with
  -- apostrophes / backslashes / dollar signs are escaped correctly by psql.
  CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
  GRANT CONNECT ON DATABASE :"app_database" TO :"app_user";
  -- Postgres 15+ revokes CREATE on schema public from PUBLIC by default, so
  -- the app role can't create its own tables / indexes / types without an
  -- explicit grant. Django migrations, ad-hoc CREATE TABLE from the app,
  -- pgsv.bm25_create_index when called by the app — all fail otherwise.
  GRANT USAGE, CREATE ON SCHEMA public TO :"app_user";
  GRANT USAGE ON SCHEMA pgsv     TO :"app_user";
  -- paradedb.score() lives in the paradedb schema; without this grant the app
  -- role hits "permission denied for schema paradedb" on any BM25 scoring query.
  GRANT USAGE ON SCHEMA paradedb TO :"app_user";
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_user";
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgsv TO :"app_user";
  GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA pgsv TO :"app_user";
  -- pgsv.version is a view; views get SELECT (not EXECUTE) to be readable.
  GRANT SELECT ON ALL TABLES IN SCHEMA pgsv TO :"app_user";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";

  -- Per-role safety ceilings. Runaway app queries never run longer than
  -- statement_timeout; idle transactions don't hold locks indefinitely.
  -- Superuser sessions stay uncapped for migrations and maintenance.
  ALTER ROLE :"app_user" SET statement_timeout                   = :'app_statement_timeout';
  ALTER ROLE :"app_user" SET lock_timeout                        = :'app_lock_timeout';
  ALTER ROLE :"app_user" SET idle_in_transaction_session_timeout = :'app_idle_tx_timeout';
EOSQL

echo "pg-search-vector: app role '$APP_USER' created (statement_timeout=${APP_STATEMENT_TIMEOUT})."

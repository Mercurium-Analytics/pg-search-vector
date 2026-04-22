#!/bin/bash
# Generate pgbouncer.ini + userlist.txt from env vars. Called once at boot.
set -e

APP_USER="${POSTGRES_APP_USER:-${POSTGRES_USER:-postgres}}"
APP_PW="${POSTGRES_APP_PASSWORD:-${POSTGRES_PASSWORD}}"

POOL_MODE="${PGBOUNCER_POOL_MODE:-transaction}"
POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-20}"
MAX_CLIENTS="${PGBOUNCER_MAX_CLIENT_CONN:-500}"
RESERVE="${PGBOUNCER_RESERVE_POOL_SIZE:-5}"
AUTH_TYPE="${PGBOUNCER_AUTH_TYPE:-scram-sha-256}"

if [ -z "$APP_PW" ]; then
  echo "pg-search-vector (pooled): POSTGRES_APP_PASSWORD / POSTGRES_PASSWORD must be set."
  exit 1
fi

cat > /etc/pgbouncer/userlist.txt <<EOF
"$APP_USER" "$APP_PW"
EOF
chmod 600 /etc/pgbouncer/userlist.txt
chown postgres:postgres /etc/pgbouncer/userlist.txt

cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
# No auth_user: we maintain userlist.txt from env, so pgbouncer validates
# client creds directly against it. auth_user would force an auth_query
# against pg_shadow/pg_authid, which the least-privileged app role can't read.
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432

# App auth uses SCRAM (strong). Admin auth uses plain text read from auth_file
# — required by pgbouncer for SHOW POOLS etc. over a client connection.
auth_type = ${AUTH_TYPE}
auth_file = /etc/pgbouncer/userlist.txt

pool_mode         = ${POOL_MODE}
default_pool_size = ${POOL_SIZE}
max_client_conn   = ${MAX_CLIENTS}
reserve_pool_size = ${RESERVE}
reserve_pool_timeout = 3
server_lifetime      = 3600
server_idle_timeout  = 600

logfile = /var/log/pgbouncer/pgbouncer.log

# Admin / stats users — can run SHOW POOLS, SHOW CLIENTS, etc.
# When connecting to the 'pgbouncer' virtual DB, auth uses the userlist.txt
# entry. Only list users that are actually in userlist.txt; 'postgres' is
# not written there, so listing it here would cause admin-console auth
# failures and is dropped on purpose.
admin_users = ${APP_USER}
stats_users = ${APP_USER}
EOF
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini

echo "pg-search-vector (pooled): pgbouncer config written (pool_mode=${POOL_MODE}, pool_size=${POOL_SIZE})"

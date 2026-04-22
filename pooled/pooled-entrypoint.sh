#!/bin/bash
# Supervises two processes: Postgres and PgBouncer.
# Postgres starts first (via the upstream docker-entrypoint.sh). Once it's
# accepting connections, PgBouncer starts. Signals forward to both; if
# either dies the container exits non-zero.

set -e

echo "=== pg-search-vector (pooled) starting ==="

# 1. Generate pgbouncer config from env
/usr/local/bin/gen-pgbouncer-config.sh

# 2. Launch Postgres in the background via its own entrypoint.
#    That script handles initdb on first boot, runs /docker-entrypoint-initdb.d
#    scripts, exec's postgres. We background it so we can also run pgbouncer.
/usr/local/bin/docker-entrypoint.sh postgres &
POSTGRES_PID=$!
echo "postgres pid=$POSTGRES_PID"

# 3. Wait for Postgres to accept connections
for i in $(seq 1 120); do
  if pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -q 2>/dev/null; then
    echo "postgres is ready after ${i}s"
    break
  fi
  # If postgres died during init, exit
  if ! kill -0 "$POSTGRES_PID" 2>/dev/null; then
    echo "FATAL: postgres exited during startup"
    wait "$POSTGRES_PID"; exit $?
  fi
  sleep 1
done

# 4. Launch PgBouncer in the background as the postgres user
su -s /bin/bash postgres -c "exec pgbouncer /etc/pgbouncer/pgbouncer.ini" &
PGBOUNCER_PID=$!
echo "pgbouncer pid=$PGBOUNCER_PID"

# 5. Forward SIGTERM / SIGINT to both children
shutdown() {
  echo "=== shutdown signal, stopping services ==="
  [ -n "$PGBOUNCER_PID" ] && kill -TERM "$PGBOUNCER_PID" 2>/dev/null || true
  [ -n "$POSTGRES_PID" ]  && kill -INT  "$POSTGRES_PID"  2>/dev/null || true
  wait
  exit 0
}
trap shutdown TERM INT

# 6. Wait for either to exit; if one dies, take the container down
wait -n "$POSTGRES_PID" "$PGBOUNCER_PID" || true
echo "=== one service exited, shutting down the other ==="
shutdown

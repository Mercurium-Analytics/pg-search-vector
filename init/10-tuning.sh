#!/bin/bash
# Runtime memory tuning — reads container RAM and writes sizing directives.
#
# Generates /etc/postgresql/conf.d/20-auto-tune.conf at first init. Users can
# override any of these via environment variables before first boot:
#
#   PGSV_SHARED_BUFFERS=4GB
#   PGSV_WORK_MEM=32MB
#   PGSV_EFFECTIVE_CACHE_SIZE=12GB
#   PGSV_MAINTENANCE_WORK_MEM=1GB
#   PGSV_PG_SEARCH_MEMORY_LIMIT=1GB
#
# This script runs INSIDE /docker-entrypoint-initdb.d so it only fires on fresh
# volumes. On existing volumes, edit postgresql.conf manually.

set -e

conf_dir=/etc/postgresql/conf.d
mkdir -p "$conf_dir"

# Detect memory — container's cgroup first, fallback to /proc/meminfo.
# Everything in KB to avoid awk scientific-notation output on large numbers.
total_kb=""
if [ -f /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != "max" ]; then
  total_kb=$(( $(cat /sys/fs/cgroup/memory.max) / 1024 ))
elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
  # cgroup v1 returns a huge sentinel when unbounded — treat as unset
  if [ "$lim" -lt 100000000000000 ]; then
    total_kb=$(( lim / 1024 ))
  fi
fi

if [ -z "$total_kb" ]; then
  total_kb=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
fi

total_mb=$(( total_kb / 1024 ))

# Sane floor for tiny containers
[ "$total_mb" -lt 512 ] && total_mb=512

auto_shared=$((total_mb / 4))                    # 25%
auto_effective=$((total_mb * 3 / 4))             # 75%
auto_maint=$((total_mb / 20))                    # 5%, cap 2GB
[ "$auto_maint" -gt 2048 ] && auto_maint=2048
auto_work=$((total_mb / (4 * 200)))              # RAM / (4 × max_connections)
[ "$auto_work" -lt 4 ] && auto_work=4
auto_pgsearch=$((total_mb / 10))                 # 10%, cap 4GB
[ "$auto_pgsearch" -gt 4096 ] && auto_pgsearch=4096
[ "$auto_pgsearch" -lt 128 ] && auto_pgsearch=128

# Parallelism — conservative. Four-worker gathers × 16MB work_mem can OOM
# a 4GB container under ILIKE seq-scan load. Keep it tight.
auto_parallel_per_gather=2
[ "$total_mb" -ge 16384 ] && auto_parallel_per_gather=4
auto_max_workers=8
[ "$total_mb" -ge 16384 ] && auto_max_workers=16

# Env var overrides
SHARED=${PGSV_SHARED_BUFFERS:-${auto_shared}MB}
EFFECTIVE=${PGSV_EFFECTIVE_CACHE_SIZE:-${auto_effective}MB}
MAINT=${PGSV_MAINTENANCE_WORK_MEM:-${auto_maint}MB}
WORK=${PGSV_WORK_MEM:-${auto_work}MB}
PGSEARCH=${PGSV_PG_SEARCH_MEMORY_LIMIT:-${auto_pgsearch}MB}
PARALLEL_PER_GATHER=${PGSV_MAX_PARALLEL_WORKERS_PER_GATHER:-${auto_parallel_per_gather}}
MAX_WORKERS=${PGSV_MAX_WORKER_PROCESSES:-${auto_max_workers}}
HASH_MULT=${PGSV_HASH_MEM_MULTIPLIER:-2.0}
STMT_TIMEOUT=${PGSV_STATEMENT_TIMEOUT:-0}
IDLE_TX_TIMEOUT=${PGSV_IDLE_IN_TRANSACTION_SESSION_TIMEOUT:-60s}

cat > "$conf_dir/20-auto-tune.conf" <<EOF
# pg-search-vector auto-tuning (generated from ${total_mb}MB container RAM)
# Override any of these via PGSV_* env vars before first boot.
shared_buffers                        = ${SHARED}
effective_cache_size                  = ${EFFECTIVE}
maintenance_work_mem                  = ${MAINT}
work_mem                              = ${WORK}
pg_search.memory_limit                = ${PGSEARCH}

# Parallelism caps — tuned to keep the worst-case parallel-seq-scan memory
# footprint bounded. Without these, ILIKE scans on big tables can OOM the
# container and send Postgres into recovery mode.
max_parallel_workers_per_gather       = ${PARALLEL_PER_GATHER}
max_worker_processes                  = ${MAX_WORKERS}
max_parallel_workers                  = ${MAX_WORKERS}
hash_mem_multiplier                   = ${HASH_MULT}

# Global safety floors. Set statement_timeout to a non-zero value (e.g. 30s)
# via PGSV_STATEMENT_TIMEOUT for production. 0 = disabled at server level;
# per-role timeouts via 20-app-role.sh are the preferred enforcement point.
statement_timeout                     = ${STMT_TIMEOUT}
idle_in_transaction_session_timeout   = ${IDLE_TX_TIMEOUT}

# shared_preload_libraries is set in 10-tuning.conf at build time so it's in
# force the first time postgres starts — initdb needs it for pgaudit /
# pg_wait_sampling / pg_prewarm CREATE EXTENSION. Don't restate it here.

# pg_prewarm — restore buffer contents after restart. Kills cold-start latency.
pg_prewarm.autoprewarm          = on
pg_prewarm.autoprewarm_interval = 300s

# pg_wait_sampling — tells you WHY a query is slow (I/O, locks, buffer waits).
pg_wait_sampling.sample_period   = 10
pg_wait_sampling.history_size    = 50000
pg_wait_sampling.profile_queries = on

# pgaudit — conservative defaults. DDL + role changes always logged. Widen via
# PGSV_PGAUDIT_LOG env var (e.g. 'ddl,role,write') if you need SOC2/ISO coverage.
pgaudit.log = '${PGSV_PGAUDIT_LOG:-ddl,role}'
pgaudit.log_catalog = off
pgaudit.log_client = off
pgaudit.log_level = log
pgaudit.log_parameter = off
pgaudit.log_relation = off
pgaudit.log_statement = on

# auto_explain — ship slow-query plans to Postgres log automatically.
# Log anything over 1s in JSON so a sidecar can ship them.
auto_explain.log_min_duration = 1000
auto_explain.log_analyze      = on
auto_explain.log_buffers      = on
auto_explain.log_timing       = on
auto_explain.log_triggers     = off
auto_explain.log_verbose      = off
auto_explain.log_nested_statements = off
auto_explain.log_format       = json
auto_explain.sample_rate      = 1.0

# pg_cron runs in the 'postgres' database by default.
cron.database_name = 'postgres'
EOF

# Make sure postgresql.conf includes our conf.d directory
# (the bookworm image's postgresql.conf already has this by convention,
# but we make it explicit for safety)
if ! grep -q "include_dir = 'conf.d'" "$PGDATA/postgresql.conf"; then
  echo "include_dir = '/etc/postgresql/conf.d'" >> "$PGDATA/postgresql.conf"
fi

echo "pg-search-vector: tuned for ${total_mb}MB — shared_buffers=${SHARED} pg_search.memory_limit=${PGSEARCH} parallel_per_gather=${PARALLEL_PER_GATHER}"

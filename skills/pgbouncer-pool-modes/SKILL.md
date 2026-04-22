---
name: pgbouncer-pool-modes
description: |
  **Trigger when user asks to:** set up PgBouncer, configure connection pooling, choose transaction vs session mode, debug "prepared statement not found" or "SET / DISCARD" errors, handle connection storms from Django / FastAPI / Celery.
  **Keywords:** PgBouncer, pool_mode, transaction mode, session mode, max_client_conn, default_pool_size, prepared statements, SET LOCAL, DISCARD ALL, connection pool exhaustion, asyncpg PgBouncer.
license: MIT
compatibility: PgBouncer 1.21+ in front of PostgreSQL 14+.
metadata:
  author: pg-search-vector
---

# PgBouncer pool modes: when each breaks your app

PgBouncer lets 500+ clients share ~20 Postgres connections. But the three pool modes have different constraints. Picking the wrong one corrupts your queries silently.

## Golden Path

For Django + FastAPI + Celery stacks: **transaction pooling**, 500 max clients, 20 pool size. This is the default in the pg-search-vector pooled image.

```
# pgbouncer.ini
[databases]
* = host=127.0.0.1 port=5432 auth_user=app

[pgbouncer]
pool_mode         = transaction
default_pool_size = 20
max_client_conn   = 500
reserve_pool_size = 5
```

App connects to port 6432 (PgBouncer). Migrations + admin connect to 5432 (direct).

```python
# .env
DATABASE_URL=postgresql://app:pw@db:6432/app       # PgBouncer
DATABASE_URL_ADMIN=postgresql://postgres:pw@db:5432/app  # direct
```

## Core Rules

### Pool mode summary

| Mode | Connection reuse | What breaks |
|---|---|---|
| `session` | 1 conn per client session (while connected) | Nothing — pure passthrough |
| `transaction` | 1 conn per transaction, returned to pool on COMMIT/ROLLBACK | `SET` outside txn, prepared statements, advisory locks, LISTEN/NOTIFY |
| `statement` | 1 conn per statement | Almost everything — don't use unless you know why |

**Transaction mode** is the right default. It's what gives you the 500:20 connection amplification.

### Never run migrations through PgBouncer transaction mode

Migrations use `SET`, may use long-running transactions, may use advisory locks for concurrency control. These break under transaction mode.

**Rule**: migrations go direct to Postgres on port 5432. App goes through PgBouncer on 6432.

```yaml
# docker-compose or Railway env
DATABASE_URL_APP:    postgresql://app:pw@db:6432/app    # app runs on this
DATABASE_URL_ADMIN:  postgresql://postgres:pw@db:5432/app  # migrations, django-admin
```

### Prepared statements break in transaction mode

The classic gotcha. Django (with psycopg 3) and asyncpg both use server-side prepared statements by default. They prepare on connection A, then try to execute on connection B (different server-side backend) — error: `prepared statement "s1" does not exist`.

**Fix per framework below.**

## Standard Patterns

### Django configuration for transaction pooling

```python
# settings.py
DATABASES = {
    "default": {
        "ENGINE":   "django.db.backends.postgresql",
        "HOST":     os.environ["DB_HOST"],           # your pgbouncer host
        "PORT":     os.environ["DB_PORT"],           # 6432
        "NAME":     os.environ["DB_NAME"],
        "USER":     os.environ["DB_USER"],
        "PASSWORD": os.environ["DB_PASSWORD"],
        "CONN_MAX_AGE": 0,                           # DISABLE connection persistence
        "CONN_HEALTH_CHECKS": True,
        "DISABLE_SERVER_SIDE_CURSORS": True,         # required for transaction mode
        "OPTIONS": {
            "connect_timeout": 10,
        },
    }
}
```

Key settings:
- `CONN_MAX_AGE = 0` — Django closes its connection after each request. PgBouncer gives you fast reconnects. Persistent app-side connections fight PgBouncer's pool.
- `DISABLE_SERVER_SIDE_CURSORS = True` — server-side cursors span multiple statements, which transaction mode breaks.
- On psycopg 3 specifically, set `options={'options': '-c default_transaction_read_only=off'}` if you see prepared-statement errors.

### FastAPI + asyncpg configuration

asyncpg caches prepared statements client-side. In transaction mode, disable:

```python
from sqlalchemy.ext.asyncio import create_async_engine

engine = create_async_engine(
    "postgresql+asyncpg://app:pw@db:6432/app",
    connect_args={
        "statement_cache_size": 0,
        "prepared_statement_cache_size": 0,
    },
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
)
```

Without these: every query under load eventually errors with "prepared statement does not exist".

### Celery workers

Celery workers are long-lived. Their DB connections outlive a single request. Force them to close between tasks:

```python
# celery.py
from celery.signals import task_postrun

@task_postrun.connect
def close_connection(**kwargs):
    from django.db import connection
    connection.close()
```

Or: `CONN_MAX_AGE = 0` as above — Django closes per-request, which for Celery means per-task.

### LISTEN/NOTIFY: use session mode or direct connect

LISTEN/NOTIFY requires a long-lived connection bound to a specific backend. Transaction mode assigns a different backend per query.

```ini
# pgbouncer.ini — add a second virtual DB for LISTEN
[databases]
* = host=127.0.0.1 port=5432 auth_user=app pool_mode=transaction
notify_db = host=127.0.0.1 port=5432 auth_user=app dbname=app pool_mode=session
```

Your notification listener connects to `notify_db`. Everyone else uses `*` (transaction).

Or skip the listener pattern and use Redis pub/sub — often simpler.

### Advisory locks: require session mode

`pg_advisory_lock()` holds for the session. Transaction mode releases the connection after each txn — the "lock" moves to some other backend. Broken.

Either:
- Use `pg_advisory_xact_lock()` (transaction-scoped) — works fine with transaction mode
- Or route the locking code to session-mode PgBouncer entry

## Sizing the pool

### `max_client_conn`
How many clients can connect to PgBouncer. Cheap — each is a small memory footprint. **500** is a good default. Raise to 1000+ if you have many async FastAPI workers, each holding a connection.

### `default_pool_size`
Server-side connections per DB. This is the real DB load. **20** per DB is reasonable for most apps; scale with your Postgres `max_connections` (PgBouncer can't open more than Postgres allows).

Formula: `default_pool_size * number_of_databases ≤ max_connections × 0.8`.

### `reserve_pool_size`
Burst capacity. If `default_pool_size = 20`, `reserve_pool_size = 5` adds 5 more connections when pool is saturated + clients waiting >`reserve_pool_timeout` (default 3s). **Keep at 5-10.**

### `max_db_connections`
Per-database cap. Set equal to `default_pool_size + reserve_pool_size` + headroom.

## Monitoring

Connect to PgBouncer's admin "database":

```bash
psql -h db -p 6432 -U app -d pgbouncer
```

Then:

```
SHOW POOLS;        -- per-db active/waiting clients + server conns
SHOW CLIENTS;      -- per-client state
SHOW SERVERS;      -- per-server connection state
SHOW STATS;        -- req/s, bytes/s, latency
SHOW CONFIG;       -- running config
```

Key metrics to alert on:
- `cl_waiting` > 0 for >1 minute → pool is saturated, raise `default_pool_size`
- `sv_used` consistently maxing `default_pool_size` → same as above
- `maxwait` > 5s → clients are queueing, user-visible latency

## Gotchas

### `SET search_path` doesn't persist

In transaction mode, `SET search_path = my_schema` at the start of a session does NOT carry over to the next query (different backend). Either:
- Use `ALTER ROLE app SET search_path = my_schema, public;` — persisted per-role
- Or `SET LOCAL search_path = ...` inside each transaction

### `DISCARD ALL` runs between transactions
PgBouncer sends `DISCARD ALL` when returning a connection to the pool. This clears: prepared statements, session vars, advisory locks, temp tables. If you RELY on any of these persisting, transaction mode breaks your app.

### Temp tables
`CREATE TEMP TABLE` only lives for the session. Transaction mode = one transaction, so temp tables vanish after COMMIT. Use CTEs (`WITH ...`) instead, OR route temp-table code to a session-mode entry.

### psycopg 3 "prepared statement already exists"
Occasionally psycopg 3 generates a colliding name. Set `prepare_threshold=None` to disable auto-prepare:

```python
# Django settings.py
"OPTIONS": {"options": "-c default_transaction_read_only=off", "prepare_threshold": None}
```

### TLS to PgBouncer
If PgBouncer runs on a different host, terminate TLS at PgBouncer. In co-located setups (one container), plain TCP is fine.

## Related skills

- `django-pgsearch-patterns` — Django-specific DB config
- `fastapi-pgsearch-patterns` — asyncpg-specific config
- `pg-cron-scheduling` — pg_cron runs on the server directly, no PgBouncer

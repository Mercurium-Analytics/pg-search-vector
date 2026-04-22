---
name: pg-cron-scheduling
description: |
  **Trigger when user asks to:** schedule SQL jobs inside Postgres, run periodic VACUUM / REINDEX, use pg_cron, schedule pg_partman maintenance, run cleanup cron in the database.
  **Keywords:** pg_cron, cron.schedule, cron.schedule_in_database, scheduled jobs, in-database cron, cron.job, cron.job_run_details, periodic VACUUM.
license: MIT
compatibility: PostgreSQL 14+ with pg_cron. Must be in shared_preload_libraries. The cron metadata lives in a specific database (default `postgres`).
metadata:
  author: pg-search-vector
---

# pg_cron: scheduled jobs inside Postgres

pg_cron gives you crontab-syntax scheduling for SQL jobs, running inside Postgres itself. No external scheduler, no Celery for simple maintenance tasks.

Use it for: VACUUM, REINDEX, pg_partman maintenance, refresh of materialized views, data retention purges, pgstattuple bloat checks.

Don't use it for: long-running ETL, app logic, or anything that needs external API calls (it can't call out).

## Golden Path

### 1. Make sure it's enabled (one-time setup)

pg_cron MUST be in `shared_preload_libraries`:

```sql
-- Check
SHOW shared_preload_libraries;
-- Should include 'pg_cron'
```

If not set, edit `postgresql.conf` (or `conf.d/`) and restart Postgres. The pg-search-vector image has this baked in.

The `cron` schema lives in ONE database (default `postgres`). You can schedule jobs against ANY database via `schedule_in_database()`.

```sql
-- Run in the `postgres` DB (the cron metadata DB)
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

### 2. Schedule your first job

```sql
-- Daily at 03:00 UTC: vacuum-analyze the largest table
SELECT cron.schedule(
  'vacuum-events',        -- job name (unique)
  '0 3 * * *',            -- cron expression
  $$VACUUM ANALYZE events$$
);
```

### 3. Schedule against a different database

```sql
-- pg_cron is installed in `postgres`, job runs in `app`
SELECT cron.schedule_in_database(
  'reindex-bm25-weekly',
  '0 4 * * SUN',
  $$REINDEX INDEX CONCURRENTLY documents_bm25$$,
  database => 'app'
);
```

### 4. Inspect + manage jobs

```sql
-- List all scheduled jobs
SELECT jobid, jobname, schedule, command, database FROM cron.job ORDER BY jobid;

-- See recent runs (did it succeed?)
SELECT jobid, runid, start_time, end_time, status, return_message
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 20;

-- Unschedule
SELECT cron.unschedule('vacuum-events');
SELECT cron.unschedule(42);  -- by jobid
```

## Core Rules

### Jobs run as the user who scheduled them
`cron.schedule()` records the executing user. For system maintenance, run these statements as `postgres` (superuser) so the jobs have permission to vacuum any table.

### Keep jobs SHORT
pg_cron spawns a Postgres backend per job invocation. Long-running jobs:
- consume a connection from `max_connections`
- miss their next scheduled slot if still running
- can't be killed cleanly without `pg_terminate_backend`

Target: under 5 minutes per run. For longer work, schedule external tooling (Celery, Railway Cron, Fly scheduled machines).

### Use the `cron.database_name` GUC for the cron metadata DB
```sql
-- Check which DB holds cron metadata
SHOW cron.database_name;  -- default: postgres
```

Our pg-search-vector image defaults to `postgres`. Your jobs can target any other DB via `schedule_in_database()`.

### Don't schedule jobs that conflict with autovacuum
Scheduled `VACUUM` while autovacuum is running on the same table = one waits for the other. Not broken, but wasted. Prefer tuning autovacuum thresholds over scheduling manual VACUUM.

## Standard Patterns

### Daily maintenance bundle

```sql
-- In the `postgres` DB
SELECT cron.schedule_in_database('partman-daily',
  '@daily',
  $$CALL partman.run_maintenance_proc()$$,
  database => 'app');

SELECT cron.schedule_in_database('refresh-analytics-hourly',
  '0 * * * *',
  $$REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_stats$$,
  database => 'app');

SELECT cron.schedule_in_database('purge-sessions-hourly',
  '15 * * * *',
  $$DELETE FROM django_session WHERE expire_date < now() - INTERVAL '7 days'$$,
  database => 'app');

SELECT cron.schedule_in_database('reindex-bm25-weekly',
  '0 3 * * SUN',
  $$REINDEX INDEX CONCURRENTLY documents_bm25$$,
  database => 'app');
```

### Bloat check + alert

```sql
CREATE TABLE bloat_alerts (
  id serial PRIMARY KEY, created_at timestamptz DEFAULT now(),
  table_name text, bloat_pct real, size_bytes bigint
);

SELECT cron.schedule_in_database('bloat-check',
  '0 6 * * MON',
  $$
    INSERT INTO bloat_alerts (table_name, bloat_pct, size_bytes)
    SELECT schemaname || '.' || relname,
           round(100 * (pgstattuple_approx(relid)).approx_free_percent, 1),
           pg_total_relation_size(relid)
    FROM pg_stat_user_tables
    WHERE schemaname='public' AND pg_total_relation_size(relid) > 1e9
      AND (pgstattuple_approx(relid)).approx_free_percent > 0.2
  $$,
  database => 'app');
```

Your app checks `bloat_alerts` and notifies the on-call channel.

### Embedding backfill job (for RAG pipelines)

```sql
-- Application-level embedding jobs should go through a real task queue
-- (Celery / Taskiq) because pg_cron can't call OpenAI. But you CAN
-- enqueue them from inside the DB:

SELECT cron.schedule_in_database('queue-embeddings',
  '*/5 * * * *',      -- every 5 minutes
  $$
    INSERT INTO embedding_queue (page_id)
    SELECT id FROM document_pages
    WHERE embedding IS NULL
      AND id NOT IN (SELECT page_id FROM embedding_queue)
    LIMIT 1000
  $$,
  database => 'app');
```

Then your FastAPI / Celery worker drains `embedding_queue`.

### `cron.job_run_details` retention

`job_run_details` grows without bound. Prune it:

```sql
SELECT cron.schedule('prune-cron-history',
  '0 2 * * *',
  $$DELETE FROM cron.job_run_details WHERE start_time < now() - INTERVAL '30 days'$$);
```

## Gotchas

### Crash recovery
If Postgres crashes mid-job, that run's `job_run_details` row shows `starting` forever. Clean up:

```sql
UPDATE cron.job_run_details
SET status = 'failed', end_time = now(), return_message = 'orphaned by restart'
WHERE status = 'starting' AND start_time < now() - INTERVAL '1 day';
```

### Job names must be unique
`cron.schedule('foo', ...)` fails if a job named `foo` already exists. Use a one-shot unschedule-then-schedule pattern in migrations:

```sql
SELECT cron.unschedule('foo') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'foo');
SELECT cron.schedule('foo', ...);
```

### Timezones
Jobs run in the Postgres server's timezone. UTC is standard; set `timezone = 'UTC'` at the cluster level for predictability. Otherwise DST surprises your schedule.

### Concurrent runs
If a job's previous run is still going when the next slot arrives, pg_cron **skips** the new slot (doesn't queue). For jobs that must never skip, use `@every 1h` style and inside the job check whether the last run completed.

### pg_cron ≠ your Django/FastAPI cron
pg_cron can run SQL. It CANNOT:
- Call external APIs (OpenAI, R2, Slack)
- Run Python code
- Read files

For anything app-side, use Celery / Taskiq / Railway Cron. pg_cron is specifically for DB-local work.

### Extension installation on managed Postgres
Some managed Postgres hosts (Heroku Postgres, AWS RDS pre-2023) don't allow pg_cron. Check before designing around it. The pg-search-vector self-hosted image has it.

## Testing / dry-run

Run a job on demand without changing its schedule:

```sql
SELECT cron.schedule('test-once', '* * * * *',
  'VACUUM ANALYZE events');
-- Run once, then unschedule
-- Wait ~1 min, see cron.job_run_details
SELECT cron.unschedule('test-once');
```

Or just run the SQL directly in a psql session — pg_cron is only about scheduling, the underlying SQL is normal.

## Related skills

- `pg-partman-partitioning` — daily partition maintenance job
- `pg-repack-runbook` — you can't pg_repack from inside pg_cron (shell tool); schedule externally
- `pg-search-bm25` — REINDEX CONCURRENTLY on bm25 index

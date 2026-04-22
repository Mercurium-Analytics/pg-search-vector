---
name: pg-repack-runbook
description: |
  **Trigger when user asks to:** reclaim disk from a bloated table, run VACUUM FULL without locking, rebuild an index online, remove table bloat, or reorganize a Postgres table in production.
  **Keywords:** pg_repack, VACUUM FULL, table bloat, online reorg, REINDEX CONCURRENTLY, dead tuples, bloat removal, reclaim disk, pg_bloat_check.
license: MIT
compatibility: PostgreSQL 11+ with pg_repack 1.4+. Requires superuser. Requires a primary key or unique not-null index.
metadata:
  author: pg-search-vector
---

# pg_repack runbook

pg_repack is the production replacement for `VACUUM FULL`. It rebuilds tables online, with no long lock, no downtime. Use it whenever bloat exceeds 20% on a table with real traffic.

## Golden Path

```bash
# Install the extension once per database
psql -c "CREATE EXTENSION pg_repack;"

# Repack a single bloated table, 4 parallel workers
pg_repack -h localhost -U postgres -d app \
  -t public.documents \
  -j 4

# Repack just an index
pg_repack -h localhost -U postgres -d app \
  --index=documents_bm25
```

The operation:
1. Creates a shadow table (same schema)
2. Copies live rows in the background (minutes to hours)
3. Installs triggers that replay concurrent INSERT/UPDATE/DELETE onto the shadow
4. Briefly (~5 seconds) acquires an `ACCESS EXCLUSIVE` lock to swap the tables atomically
5. Drops the old bloated table

Downtime-equivalent: ~5 seconds at the swap. Reads and writes flow normally for the rest of the rebuild.

## Core Rules

### Prerequisites — check before running
- `CREATE EXTENSION pg_repack` installed in the target DB
- Superuser credentials
- **Primary key or unique not-null index** on the table (pg_repack needs to identify rows for trigger replay)
- **2× the table size free on disk** during the repack (original + shadow coexist)
- Table not currently locked by anything else

### Never repack during a migration
Don't run pg_repack while Django/Alembic migrations are applying. Trigger installation conflicts with DDL locks. Schedule in maintenance windows outside migration events.

### Monitor progress
```sql
SELECT
  query_start,
  state,
  wait_event_type,
  query
FROM pg_stat_activity
WHERE application_name LIKE '%pg_repack%';
```

## Standard Patterns

### When to repack: measure bloat first

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT
  schemaname || '.' || relname AS table,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  round(100 * (pgstattuple_approx(relid)).approx_free_percent, 1) AS bloat_pct
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND pg_total_relation_size(relid) > 100 * 1024 * 1024   -- >100 MB
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;
```

Trigger threshold: **repack when `bloat_pct > 20%`** for large tables (>1 GB), or >30% for small tables.

### Schedule automatic repack via pg_cron

```sql
-- Weekly bloat check + conditional repack (pseudocode; pg_cron can't run shell)
-- Use REINDEX CONCURRENTLY for indexes (built into Postgres, no superuser needed)

SELECT cron.schedule_in_database(
  'weekly-reindex-bm25',
  '0 3 * * SUN',                     -- Sunday 03:00
  'REINDEX INDEX CONCURRENTLY documents_bm25',
  'app'
);
```

For full table repack, invoke pg_repack from an external cron (Railway Cron / Fly scheduled machine) that has a psql client + pg_repack binary.

### Repacking a partition

pg_repack works per partition, not across parent:

```bash
# For a time-partitioned hypertable or native partition
pg_repack -h ... -d app -t public.events_2026_01
pg_repack -h ... -d app -t public.events_2026_02
# ...
```

Parallelize by running multiple pg_repack invocations simultaneously on different partitions (they don't conflict).

### Repacking only an index

When the heap is fine but an index (especially a bm25 or hnsw index) is bloated:

```bash
pg_repack -h ... -d app --index=documents_bm25
```

Equivalent to `REINDEX INDEX CONCURRENTLY` but without Postgres's concurrent-reindex lock pattern. Safer for very large indexes.

### Aborting gracefully
```bash
pg_repack --no-kill-backend ...
```
If the repack is taking too long and you need to stop: SIGINT it, then clean up its leftovers with `--no-kill-backend` on the next run. It resumes where it left off.

## Gotchas

### "Cannot repack" errors
| Error | Cause | Fix |
|---|---|---|
| `relation ... has no primary key` | Table lacks PK or unique non-null index | Add one, then repack |
| `relation ... has triggers` | Some trigger conflicts with pg_repack's own triggers | `--no-superuser-check`, or drop conflicting trigger temporarily |
| `relation ... is being used` | Someone holds a lock | Wait, or check `pg_stat_activity` |

### Disk exhaustion mid-repack
If you run out of disk while pg_repack is rewriting a 100 GB table, Postgres will error out and leave the shadow table behind. Clean up:

```sql
-- Drop leftover shadow tables
DROP TABLE IF EXISTS repack.table_<oid>;
DROP TRIGGER IF EXISTS z_repack_trigger ON public.<your_table>;
```

Prevent this: measure free disk before. Need **2 × current table size** minimum.

### Don't run pg_repack on UNLOGGED tables
UNLOGGED tables don't participate in the trigger-based row capture properly. Either make them LOGGED first or skip repack.

### DO repack bm25 indexes regularly
pg_search's bm25 index accumulates write-amplification bloat. After heavy ingest bursts, the index's internal segments fragment. Repack after big writes:

```bash
pg_repack --index=documents_bm25
```

Or schedule monthly via pg_cron (`REINDEX INDEX CONCURRENTLY`).

### Repacking is NOT backup
A repack operation can fail and leave the table with orphaned triggers. Always have backups before repacking large tables.

## When NOT to use pg_repack

- **Tiny tables** (<100 MB): `VACUUM FULL` is fine, takes seconds
- **Cold archive tables** nobody queries: `VACUUM FULL` in a maintenance window is fine
- **Partitioned tables at the parent level**: repack children individually, never the parent

## Dashboard: who's repacking right now

```sql
SELECT
  now() - query_start AS elapsed,
  state,
  wait_event,
  query
FROM pg_stat_activity
WHERE application_name = 'pg_repack'
ORDER BY query_start;
```

## Related skills

- `pg-cron-scheduling` — schedule repack via in-DB cron
- `pg-search-bm25` — why bm25 indexes specifically need regular repack
- `pg-partman-partitioning` — partition large tables to make repack cheap (per-partition)

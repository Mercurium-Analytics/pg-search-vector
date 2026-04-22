---
name: pg-partman-partitioning
description: |
  **Trigger when user asks to:** partition a large Postgres table, handle 100M+ rows, use pg_partman, partition by time/date/range, manage partition lifecycle, or drop old data cheaply.
  **Keywords:** pg_partman, declarative partitioning, PARTITION BY RANGE, PARTITION BY LIST, time-series partitioning, partition pruning, partition retention, drop partition.
license: MIT
compatibility: PostgreSQL 14+, pg_partman 5+ installed in schema `partman`.
metadata:
  author: pg-search-vector
---

# pg_partman + declarative partitioning for large tables

Past ~100M rows, single tables become operationally painful: VACUUM takes hours, indexes grow unwieldy, schema changes are multi-hour locks. **Partition** the table, and each partition becomes a manageable ~10M-row piece that you can maintain, repack, and drop independently.

pg_partman automates the tedious lifecycle bits: creating future partitions, dropping old ones, retention policies.

## Golden Path

### Time-based (most common — event logs, telemetry, measurements)

```sql
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

-- 1. Define the parent table, partitioned by a timestamp column
CREATE TABLE events (
    id         bigserial,
    user_id    bigint NOT NULL,
    created_at timestamptz NOT NULL,
    payload    jsonb,
    PRIMARY KEY (id, created_at)            -- PK must include partition column
) PARTITION BY RANGE (created_at);

-- 2. Let pg_partman create the first + future partitions automatically
SELECT partman.create_parent(
  p_parent_table       := 'public.events',
  p_control            := 'created_at',
  p_interval           := '1 month',        -- partition size
  p_premake            := 4                 -- pre-create 4 months ahead
);

-- 3. Schedule partman's background maintenance (create + drop)
SELECT cron.schedule(
  'partman-maintenance', '@daily',
  $$CALL partman.run_maintenance_proc()$$
);

-- 4. (Optional) Set retention: drop partitions older than 12 months
UPDATE partman.part_config
SET retention = '12 months', retention_keep_table = false
WHERE parent_table = 'public.events';
```

After this: inserts into `events` land in the right partition automatically. Queries filtered by `created_at` only scan relevant partitions. Old data is dropped for you. Zero manual partition management.

### List-based (jurisdictions, tenants, categories)

```sql
CREATE TABLE registry_records (
    id                bigserial,
    jurisdiction_code text NOT NULL,
    name              text NOT NULL,
    PRIMARY KEY (id, jurisdiction_code)
) PARTITION BY LIST (jurisdiction_code);

CREATE TABLE registry_gb   PARTITION OF registry_records FOR VALUES IN ('gb');
CREATE TABLE registry_usny PARTITION OF registry_records FOR VALUES IN ('us_ny');
CREATE TABLE registry_usde PARTITION OF registry_records FOR VALUES IN ('us_de');
CREATE TABLE registry_fr   PARTITION OF registry_records FOR VALUES IN ('fr');
CREATE TABLE registry_rest PARTITION OF registry_records DEFAULT;
```

pg_partman doesn't automate list partitioning — manage partitions manually. The pattern is useful for fixed, bounded sets (jurisdictions, tenant tiers).

## Core Rules

### Primary key must include the partition column
Postgres requires this for declarative partitioning. If your PK was `id bigserial`, change to `(id, created_at)` or `(id, jurisdiction_code)`.

Django: set `PRIMARY KEY` in a migration with `RunSQL`, as the ORM doesn't natively express compound partition-aware PKs.

### Choose partition size carefully
- Too small (daily for 1M rows/month) → partition metadata overhead, planner slowness
- Too big (yearly for a high-ingest table) → defeats the purpose

Rule of thumb: aim for **10M-50M rows per partition** or **1-10 GB per partition**. Monthly is typical for event-heavy tables.

### Indexes propagate, bm25 doesn't (easily)
A normal btree index created on the parent is automatically created on each child partition:

```sql
CREATE INDEX ON events (user_id);   -- indexes every partition
```

**bm25 indexes**: pg_search supports partitioned tables but creating one per-partition is manual. Script it:

```sql
DO $$
DECLARE p text;
BEGIN
  FOR p IN SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent = 'events'::regclass
  LOOP
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I_bm25 ON %s USING bm25 (id, payload) WITH (key_field=''id'')',
      regexp_replace(p, '[^a-z0-9_]', '_', 'g'), p
    );
  END LOOP;
END $$;
```

### Filter queries by the partition key
```sql
-- GOOD: only scans Jan + Feb partitions
SELECT * FROM events
WHERE created_at BETWEEN '2026-01-01' AND '2026-02-28'
  AND user_id = 42;

-- BAD: scans every partition (no pruning)
SELECT * FROM events WHERE user_id = 42;
```

If your app frequently queries without the partition column, partitioning doesn't help — choose a different partition key.

## Standard Patterns

### Per-partition VACUUM / repack
Bloat management happens per-partition, not on the parent:

```bash
pg_repack -h db -d app -t events_p2026_01
pg_repack -h db -d app -t events_p2026_02
```

Run in parallel with a `GNU parallel` wrapper. Big win vs. repacking a single 10 GB table.

### Partition-aware analytics
```sql
-- Per-month count without scanning all partitions
SELECT
  inhrelid::regclass AS partition,
  (SELECT count(*) FROM pg_class WHERE oid = inhrelid)  -- use pg_class reltuples for speed
FROM pg_inherits
WHERE inhparent = 'events'::regclass
ORDER BY partition;
```

### Moving old partitions to cheaper storage
```sql
-- Put cold partitions on a slower tablespace
CREATE TABLESPACE cold LOCATION '/mnt/slow-ssd';

ALTER TABLE events_p2025_01 SET TABLESPACE cold;
```

Or: detach + archive to S3 via COPY, then drop:

```sql
COPY events_p2025_01 TO PROGRAM 'gzip | aws s3 cp - s3://.../events_p2025_01.csv.gz';
DROP TABLE events_p2025_01;
```

### Dropping a partition is atomic + fast

```sql
-- Takes milliseconds regardless of row count
DROP TABLE events_p2024_01;

-- Or detach to keep the data as a non-partitioned table
ALTER TABLE events DETACH PARTITION events_p2024_01;
```

`DELETE FROM events WHERE created_at < '2024-01-01'` on 800M rows takes hours. `DROP TABLE` on the partition containing those rows takes seconds.

### pg_partman retention policy

```sql
UPDATE partman.part_config
SET retention = '6 months',
    retention_keep_table = false,   -- actually DROP the partition
    retention_keep_index = false
WHERE parent_table = 'public.events';
```

Run by `partman.run_maintenance_proc()` on schedule. Drops partitions older than 6 months automatically.

## Migrating an existing non-partitioned table

You cannot add partitioning in-place. Two-step migration:

```sql
-- 1. Rename the old table
ALTER TABLE events RENAME TO events_legacy;

-- 2. Create new partitioned table
CREATE TABLE events (...) PARTITION BY RANGE (created_at);
SELECT partman.create_parent('public.events', 'created_at', 'native', '1 month');

-- 3. Copy old data in (expensive; use COPY or INSERT ... SELECT in batches)
INSERT INTO events SELECT * FROM events_legacy;  -- routes to partitions automatically

-- 4. Drop old table
DROP TABLE events_legacy;
```

On very large tables (100M+), do step 3 in batches (WHERE created_at BETWEEN ...) and schedule during low-traffic windows.

Alternative: `pg_partman.partition_data_proc()` copies in chunks with progress logging.

## Gotchas

### Foreign keys on partitioned tables (limited before PG 15)
- **PG 12-14**: FK from partitioned table → regular table works. FK from regular table → partitioned table does NOT.
- **PG 15+**: both directions supported.

Plan schema accordingly.

### Partitioning column cannot be updated across partitions
`UPDATE events SET created_at = '2026-03-01'` on a row currently in January's partition: error on PG 10. Since PG 11: it moves the row but takes a row-level lock on both partitions.

Avoid moving rows across partitions — if `created_at` changes frequently (it shouldn't), partition by something stable.

### `SELECT ... FOR UPDATE` and partition-wise joins
Some planner optimizations require `enable_partitionwise_join = on` + `enable_partitionwise_aggregate = on`. Set these globally:

```sql
ALTER SYSTEM SET enable_partitionwise_join = on;
ALTER SYSTEM SET enable_partitionwise_aggregate = on;
SELECT pg_reload_conf();
```

### `CREATE INDEX CONCURRENTLY` on partitioned tables (PG 14+)
Must be run on each partition individually. PG will error if you try it on the parent without partitions.

### Django migrations don't natively support partitioning
Use `migrations.RunSQL(...)` for both the `CREATE TABLE ... PARTITION BY` and `partman.create_parent(...)`. Django's schema editor doesn't understand partitioned tables fully.

## When NOT to partition

- Table <10M rows: partitioning adds complexity without win
- Queries don't filter by a natural partition key: no pruning benefit
- Heavy cross-partition JOINs: partitionwise join is better than non-partitioned, but worse than a single table
- Tiny partitions (<1M rows each): planner overhead dominates

## Related skills

- `pg-cron-scheduling` — run `partman.run_maintenance_proc()` daily
- `pg-repack-runbook` — repack per-partition
- `pg-search-bm25` — bm25 indexes across partitions

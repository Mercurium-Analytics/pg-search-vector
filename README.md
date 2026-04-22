# pg-search-vector

Postgres 17 with **pgvector** (vector similarity) and **pg_search** (Lucene-quality BM25) pre-installed, tuned for hybrid lexical + semantic search.

One image. One database. One query language. Two retrieval modes.

## What's inside

| | Version | Purpose |
|---|---|---|
| Postgres | 17 (Debian bookworm) | base |
| pgvector | 0.8.2 | vector similarity (HNSW / IVFFlat, cosine / L2 / inner product) |
| pg_search | 0.23.0 | BM25 full-text, prefix / phrase / fuzzy / regex |
| pg_stat_statements | built-in | query telemetry |
| auto_explain | built-in | slow-query plan capture |
| pgsv | 0.2.0 | helpers: `bm25_preset`, `bm25_create_index`, `hybrid_search` |

## Why this image

Running pgvector and pg_search in the same Postgres gets you **hybrid retrieval** — BM25 lexical match + vector semantic similarity, fused in one SQL query. Neither extension ships with the other bundled. This does.

## Quick start

```bash
docker run -d \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD=postgres \
  -v pg_data:/var/lib/postgresql/data \
  ghcr.io/mercurium-analytics/pg-search-vector:pg17
```

Connect + enable:

```bash
psql postgresql://postgres:postgres@localhost:5432/postgres
```

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pg_search;
-- pgsv helpers already loaded by init
SELECT * FROM pgsv.version;
```

## Hybrid search — 5-line example

```sql
CREATE TABLE items (
  id        bigserial PRIMARY KEY,
  name      text,
  embedding vector(768)
);

-- Postgres's WITH() reloption parser doesn't evaluate function calls, so
-- we ship a helper that composes the DDL server-side (preset → JSON → literal).
CALL pgsv.bm25_create_index('items_bm25', 'items', 'id', 'name', 'autocomplete');
CREATE INDEX items_hnsw ON items USING hnsw (embedding vector_cosine_ops);

-- Top 10 hybrid matches for 'robert' + query embedding
SELECT h.*, i.name
FROM pgsv.hybrid_search('items', 'id', 'name', 'embedding',
                        'robert', :query_vec::vector, 10) h
JOIN items i USING (id);
```

## Configuration

### Environment variables

| Var | Default | Description |
|---|---|---|
| `POSTGRES_PASSWORD` | *(required)* | Superuser password |
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_DB` | `postgres` | Initial database |
| `POSTGRES_APP_USER` | `app` | Non-superuser for application connections |
| `POSTGRES_APP_PASSWORD` | *unset* | If set, creates a least-privilege app role |
| `PGSV_SHARED_BUFFERS` | 25% of RAM | Postgres shared_buffers |
| `PGSV_EFFECTIVE_CACHE_SIZE` | 75% of RAM | Planner hint |
| `PGSV_MAINTENANCE_WORK_MEM` | 5% of RAM (cap 2GB) | Index build memory |
| `PGSV_WORK_MEM` | RAM / (4 × max_conn) | Sort / hash memory per op |
| `PGSV_PG_SEARCH_MEMORY_LIMIT` | 10% of RAM (cap 4GB) | pg_search memtable budget |

The container auto-detects its cgroup memory limit at first boot and tunes accordingly. Override individual values with env vars before first init.

### Security — use the app role

```yaml
# docker-compose.yml
services:
  db:
    image: ghcr.io/mercurium-analytics/pg-search-vector:pg17
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_SUPERUSER_PASSWORD}    # migrations only
      POSTGRES_APP_USER: app
      POSTGRES_APP_PASSWORD: ${POSTGRES_APP_PASSWORD}      # used by Django, Celery, etc.
```

Django's `DB_USER=app`, `DB_PASSWORD=$POSTGRES_APP_PASSWORD`. Superuser is only used when you `docker exec` in for maintenance. Dramatically smaller blast radius.

## Deployment

### Railway — one click

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/pg-search-vector)

Or manually:
1. Railway → "Deploy from Docker Image"
2. Image: `ghcr.io/mercurium-analytics/pg-search-vector:pg17-pooled`
3. Attach a Volume at `/var/lib/postgresql/data`
4. Set `POSTGRES_PASSWORD`, optionally `POSTGRES_APP_PASSWORD`
5. Deploy

### Fly.io

```toml
# fly.toml
app = "my-db"
primary_region = "ord"
[build]
image = "ghcr.io/mercurium-analytics/pg-search-vector:pg17"
[mounts]
source = "pg_data"
destination = "/var/lib/postgresql/data"
[env]
POSTGRES_PASSWORD = "secret"
[[services]]
protocol = "tcp"
internal_port = 5432
```

### Kubernetes / docker-compose / bare metal

Same image, standard Postgres conventions. Mount the data volume, set `POSTGRES_PASSWORD`, expose 5432.

## Backups (WAL-G → S3 / R2)

Set these env vars and the container configures continuous archiving + a
weekly base backup on first boot. An initial base backup is scheduled via
`pg_cron` and runs within a minute of the final Postgres start — the job
auto-unschedules after the first success and retries every minute if it
fails (bad creds, bucket ACL, etc.).

```
WALG_S3_PREFIX=s3://my-bucket/walg
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # R2; omit for AWS S3
AWS_REGION=auto                                            # auto for R2
```

### Turning WAL-G on after the volume exists

The init scripts in `/docker-entrypoint-initdb.d/` only fire on fresh volumes,
and `archive_mode = on` requires a full Postgres restart. If you want to
enable WAL-G on a cluster that's already running:

```bash
docker exec \
  -e WALG_S3_PREFIX=s3://my-bucket/walg \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_ENDPOINT=... -e AWS_REGION=auto \
  <container> bash /usr/local/bin/pgsv-walg-enable.sh

docker restart <container>   # MUST restart for archive_mode to take effect
```

Restore: see [bin/wal-g-restore.sh](bin/wal-g-restore.sh).

## Sizing guide

| Dataset | Recommended RAM | Volume |
|---|---|---|
| < 10M rows (prototypes) | 2 GB | 20 GB |
| 10-100M rows | 8 GB | 100 GB |
| 100-500M rows | 16 GB | 250 GB |
| 500M-1B rows | 32 GB | 500 GB+ NVMe |
| > 1B rows | 64 GB+ + partitioning | 1 TB+ |

pg_search BM25 index is ~1.5-2× the indexed text column size. HNSW index is ~1.2× the vector column size.

## Benchmarks

Full numbers in [PERFORMANCE.md](PERFORMANCE.md). Highlights from a 5.28M-row
test with PgBouncer in front:

| | direct :5432 | pooled :6432 |
|---|---|---|
| 10 clients | 1,532 tps | 1,630 tps |
| 50 clients | 2,282 tps | 1,409 tps |
| 100 clients | 256 tps (collapsing) | **610 tps** |
| 200 clients | crashed | **594 tps** |

BM25 index build: 106s for 5.28M rows → projected ~13 min at 39M rows.
Index size 243 MB → projected ~1.76 GB at 39M rows.

Warm p50: 85–115ms for autocomplete seeds. 100–1000× faster than `ILIKE`.

See [PUBLISH.md](PUBLISH.md) for the Railway + GHCR + PyPI publishing
checklist.

## Tags

- `ghcr.io/mercurium-analytics/pg-search-vector:v0.4.0-pg17` — pinned
- `ghcr.io/mercurium-analytics/pg-search-vector:0.4-pg17` — minor version pin
- `ghcr.io/mercurium-analytics/pg-search-vector:latest-pg17` — latest, PG17
- `ghcr.io/mercurium-analytics/pg-search-vector:v0.4.0-pg17-pooled` — pinned, PgBouncer bundled
- `ghcr.io/mercurium-analytics/pg-search-vector:latest-pg17-pooled` — latest, pooled

Built for `linux/amd64` + `linux/arm64`.

## Django integration

Use [`pg-search-vector-django`](./django/README.md) — thin adapter for ORM lookups + annotations:

```python
from pgsv import BM25, HybridSearch

qs = Items.objects.filter(name__bm25='robert').order_by('-id')[:10]

qs = Items.objects.annotate(
    rrf=HybridSearch('name', 'embedding', 'robert', [0.1, 0.2, ...]),
).order_by('-rrf')[:10]
```

## License

This image's packaging: **MIT**.

Upstream:
- Postgres: PostgreSQL License
- pgvector: PostgreSQL License
- pg_search: **AGPL-3.0** (affects modifications to pg_search, not your application)

Using the extensions unmodified in a SaaS does not trigger AGPL's network copyleft. Forking pg_search and hosting the fork does.

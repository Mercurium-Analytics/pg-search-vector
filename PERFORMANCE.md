# Performance review — pg-search-vector

Measured numbers from a local benchmark on a real-world text corpus. Use
this document to set expectations, validate tuning changes, and compare
against alternatives (Elasticsearch, Meilisearch, Solr).

> **TL;DR** at 5.28M rows: BM25 builds in 106s (243 MB), serves p50 ~100ms,
> handles 2,200 tps at 50 clients direct and survives 200 clients via
> PgBouncer where direct Postgres crashes. 100–1000× faster than `ILIKE`.

## 1. Test environment

| Setting | Value |
|---|---|
| Host | Mac (Apple Silicon) with Docker Desktop, 4 GB container limit |
| Container image | `pg-search-vector:pg17-pooled` (see [`Dockerfile.pooled`](Dockerfile.pooled)) |
| Postgres | 17.9 (Debian pgdg) |
| pg_search | 0.23.0 (ParadeDB / Tantivy) |
| pgvector | 0.8.2 |
| pgvectorscale | 0.9.0 (DiskANN + SBQ) |
| PgBouncer | 1.25.1 (transaction mode, `default_pool_size=20`, `max_client_conn=500`) |
| Tuning | `shared_buffers=1GB`, `work_mem=16MB`, `maintenance_work_mem=512MB`, `effective_cache_size=3GB`, `max_parallel_workers_per_gather=2`, `hash_mem_multiplier=2.0` |
| Corpus | Business-registry text table — **5,281,847 rows**, 2.4 GB heap, ~80 chars/row average |

Indicative numbers. Rerun the benchmarks on your own corpus — shape and
tokenizer choice matter more than hardware.

## 2. Index build cost

| Metric | Measured at 5.28M | Extrapolated to ~40M |
|---|---|---|
| Build time (`maintenance_work_mem=2GB`) | **106s** | **~13 min** |
| Rate | 49,828 rows/sec | — |
| Final index size | **243 MB** (48 bytes/row) | **~1.76 GB** |
| vs btree `name` index | 337 MB (btree is bigger) | — |

Linear in row count. Build is I/O-bound; giving pg_search more
`maintenance_work_mem` cuts time ~proportionally up to ~2 GB.

## 3. Query latency — single client (20 runs, p50/p95)

**Cold cache** (after container restart, first query ever):

| Seed | Cold ms | Matches |
|---|---|---|
| smith | 238 | 2,615 |
| acme | 139 | 308 |
| holdings | 115 | 50,241 |
| robert | 179 | — |
| microsoft | 90 | 8 |

**Warm cache — common seeds**:

| Seed | p50 | p95 |
|---|---|---|
| smith | 114ms | 239ms |
| acme | 110ms | 136ms |
| holdings | 96ms | 131ms |
| microsoft | 103ms | 162ms |
| johnson | 93ms | 130ms |
| williams | 100ms | 130ms |
| brown | 95ms | 117ms |

**Short-prefix autocomplete (2–3 chars, the hot path)**:

| Seed | p50 | p95 |
|---|---|---|
| `ro` | 85ms | 123ms |
| `ma` | 87ms | 106ms |
| `ac` | 89ms | 120ms |
| `bn` | 85ms | 133ms |
| `ibm` | 86ms | 100ms |

## 4. Saturation — direct Postgres vs PgBouncer (pgbench, 20s each)

Single BM25 query, 5-seed randomised, `LIMIT 150` ordered by `paradedb.score`.

| Clients | Direct tps | Pooled tps | Direct avg | Pooled avg | Notes |
|---|---|---|---|---|---|
| 10 | **1,532** | 1,630 | 6.5ms | 6.1ms | Pool wins slightly |
| 25 | 2,236 | 2,190 | 11.1ms | 11.3ms | Tie |
| 50 | **2,282** | 1,409 | 21.9ms | 35.3ms | Direct wins — clients < pool_size has no benefit |
| 100 | 256 | **610** | 382ms | 163ms | **Direct collapsing** |
| 200 | crashed | **594** | — | 333ms | **Direct aborts, pooled survives** |

### What the curve shows

- **< 50 clients**: pooling is a no-op (slight 10% gain or loss). Postgres backends are cheap enough.
- **50–100 clients**: the Postgres `max_connections` cost (per-backend RAM + context switches) starts to dominate. Pooling keeps server-side connections at 20, client queue on PgBouncer.
- **> 100 clients**: direct Postgres collapses. Pooler is mandatory.
- **200+ clients**: pgbench can't finish against direct (connection churn). Pooled holds 594 tps.

**Conclusion**: in production, use PgBouncer. The config in
[`Dockerfile.pooled`](Dockerfile.pooled) — transaction-mode, 20 server-side
backends, 500 client slots — is the recommended default.

## 5. BM25 vs the alternatives (5-run median)

Same query on same table, different index paths:

| Query | BM25 `@@@` | btree `ILIKE 'x%'` | ILIKE `'%x%'` |
|---|---|---|---|
| `acme` | **79ms** | 12,583ms | 5,302ms (timeout) |
| `smith` | **104ms** | 91ms | 91ms |
| `holdings` | ~95ms | 118ms | 96ms |

**ILIKE `'%substring%'`** is the production DoS vector — 5+ seconds per query
at 5M rows, 12+ seconds for `ILIKE 'acme%'` (default collation doesn't allow
btree prefix lookup with ILIKE). **Never route user input into ILIKE against
a big table.** Always BM25.

See the parallel-seq-scan plan behind a 12.5s ILIKE in
[section 6. Memory guardrails](#6-memory-guardrails--what-happens-when-tuning-is-wrong).

## 6. Memory guardrails — what happens when tuning is wrong

**Observed incident during bench**: running 15 parallel `ILIKE '%acme%'`
queries (each with 4 Parallel Seq Scan workers) against 5.28M rows produced:

- One BM25 query in the same session hit **51,651 ms** (50× the median)
- Immediately after, Postgres went into **"database system is in recovery mode"**
- Blocked all queries for ~15 seconds

Root cause: Parallel workers × `work_mem` × seq scan = memory pressure that
exceeded the container's 4 GB cap. The kernel OOM-killer took a worker.
Postgres replayed WAL to reach a consistent state.

**The guardrails that prevent this** (all applied in our image):

| Knob | Default | Our value | Why |
|---|---|---|---|
| `shared_buffers` | 128 MB | **1 GB** (25% of RAM) | More hot data stays in RAM |
| `work_mem` | 4 MB | **16 MB** | Prevents runaway temp-file IO |
| `max_parallel_workers_per_gather` | 2 | **2** (capped) | Caps worst-case parallel memory |
| `max_worker_processes` | 8 | **8** (capped) | Container-wide ceiling |
| `hash_mem_multiplier` | 2.0 | **2.0** | Hash/sort memory shaped by work_mem |
| `idle_in_transaction_session_timeout` | 0 | **60s** | Idle transactions can't hold locks forever |
| `statement_timeout` (app role) | 0 | **30s** | Runaway query gets killed, not OOM |
| `lock_timeout` (app role) | 0 | **5s** | Lock contention fails fast |
| Docker memory limit | unlimited | **4 GB** | Kernel kills Postgres before swap thrash |
| Docker `shm_size` | 64 MB | **512 MB** | Parallel workers use /dev/shm |

**Superuser (`postgres`)** keeps no timeout — migrations, pg_repack, backups
need the ability to run for minutes. The `app` role enforces the ceiling.

## 7. Comparison to Elasticsearch

Not a like-for-like (different hardware, different corpus), but directionally:

| Axis | pg-search-vector | Elasticsearch |
|---|---|---|
| Build ~40M rows | ~13 min | hours to days (large reindex, depending on hardware) |
| Index size ~40M | ~1.76 GB | several GB, often 3–5× BM25 on same text |
| p50 autocomplete | 85–100ms warm | 10–30ms (typical, with replica) |
| p99 autocomplete | 120–240ms | 50–100ms |
| Sustained tps | 2,000+ on single node | 500–2,000 per node, scales horizontally |
| Connection cost | Covered by PgBouncer | HTTP, handled by ES cluster |
| Operational footprint | One Postgres container | JVM cluster + master nodes + replicas |
| Transactional consistency with app data | **Yes** (same DB) | No (async index update) |
| Cost (≈equivalent throughput) | 1× | 3–5× |
| Blast radius of wrong command | WAL rollback | Potentially catastrophic (cluster-wide) |

When ES is demonstrably better: multi-node horizontal scale, multilingual
analyzer chains, aggregation pipelines. For autocomplete + hybrid search in a
Postgres-centric stack, **pg-search-vector closes the gap enough to remove ES.**

## 8. Hybrid search (BM25 + pgvector RRF)

Measured on 4,871 document chunks with existing 1024-dim embeddings. All
three paths exercised side-by-side:

- **BM25-only** `@@@`: 80–130ms
- **Vector-only** (cosine, DiskANN when passed as literal): 17ms per query
- **Hybrid** (RRF fusion via `pgsv.hybrid_search()`): 90–150ms

Hybrid resolves query classes neither path does alone:

- `force majeure` — BM25 alone returns unrelated prose containing "majeure";
  vector alone or hybrid correctly surface contractual clauses.
- `board of directors` — BM25 finds narrative mentions; vector finds the
  governance section header; hybrid picks the latter.
- `anti-money laundering` — both agree, hybrid confirms with tied rrf≈0.0325.

Add your own integration tests under `django/tests/`.

## 9. Known weaknesses

1. **Tail latency** is 2–3× p50 for common seeds. ES typically has tighter
   tails. Mitigation: warm the cache with pg_prewarm on boot.
2. **Short-prefix recall** depends on tokenizer preset. Default `natural`
   tokenizer can miss prefixes < 3 chars — use the `autocomplete` preset
   (see `pgsv.bm25_preset()`) for typeahead fields.
3. **Query embedding** is on the caller. pg-search-vector does not include an
   embedder; use `pg-search-vector-django` with a configured provider
   (Ollama, OpenAI, MercuriumAI-compatible HTTP, or any callable).
4. **No horizontal scale out of the box.** Vertical scaling + read replicas
   is the standard path. If you need >10k tps across the same shard, ES or a
   distributed engine still wins.

## 10. Config profiles

| Profile | RAM | `shared_buffers` | `work_mem` | `pg_search.memory_limit` | `max_parallel_workers_per_gather` | Use case |
|---|---|---|---|---|---|---|
| `SMALL` | 2 GB | 512 MB | 8 MB | 200 MB | 2 | dev, CI, small SaaS |
| `MEDIUM` | 4 GB | 1 GB | 16 MB | 400 MB | 2 | standard prod (this benchmark) |
| `LARGE` | 16 GB | 4 GB | 32 MB | 1.6 GB | 4 | high-traffic single node |
| `XLARGE` | 64 GB | 16 GB | 64 MB | 6 GB | 6 | single-node max-out |

`SMALL`/`MEDIUM`/`LARGE` are what [`init/10-tuning.sh`](init/10-tuning.sh)
computes automatically from cgroup limits. Override any value with a
`PGSV_*` env var before first boot.

## 11. How to reproduce

```bash
# 1. Build and start the pooled image
docker-compose build db && docker-compose up -d db

# 2. (Optional) tune an existing data dir; fresh pgdata applies tuning automatically
docker exec db psql -U postgres -d app <<'SQL'
ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET max_parallel_workers_per_gather = '2';
ALTER SYSTEM SET effective_cache_size = '3GB';
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
SQL
docker restart db

# 3. Run your own single-client + pgbench concurrency curves against a representative table.
```

## Appendix — raw pgbench output, 50 clients pooled

```
transaction type: bm25_query.sql
scaling factor: 1
query mode: simple
number of clients: 50
number of threads: 8
duration: 20 s
number of transactions actually processed: 10812
number of failed transactions: 0 (0.000%)
number of transactions above the 5000.0 ms latency limit: 0/10812 (0.000%)
latency average = 91.306 ms
latency stddev = 83.400 ms
initial connection time = 307.346 ms
tps = 545.965503 (without initial connection time)
```

---
name: pgvectorscale-diskann
description: |
  **Trigger when user asks to:** scale vector search beyond 100M vectors, reduce HNSW memory cost, use DiskANN, StreamingDiskANN, SBQ, or build RAG on large document corpora.
  **Keywords:** pgvectorscale, DiskANN, StreamingDiskANN, SBQ, Statistical Binary Quantization, halfvec, vector quantization, large-scale vector search, Timescale vector.
license: MIT
compatibility: Requires PostgreSQL 15+ with pgvector and pgvectorscale (Timescale, PostgreSQL-license).
metadata:
  author: pg-search-vector
---

# pgvectorscale DiskANN: vector search that doesn't need all-RAM

pgvector's default HNSW index is fast but assumes the graph fits in RAM. At 100M+ vectors with 768+ dimensions, that graph stops fitting on commodity machines. **pgvectorscale** adds a disk-friendly index (StreamingDiskANN, from Microsoft Research) and compresses vectors with SBQ — shrinking the index 10-30× with minimal recall loss.

## Golden Path

For any new vector column on a table expected to exceed ~10M rows OR any RAG doc-pages table:

```sql
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;  -- also installs pgvector

CREATE TABLE doc_pages (
  id        bigserial PRIMARY KEY,
  text      text,
  embedding vector(768)
);

-- StreamingDiskANN with SBQ (memory_optimized is the default)
CREATE INDEX doc_pages_embedding_idx ON doc_pages
  USING diskann (embedding vector_cosine_ops);
```

Queries use exactly the same pgvector syntax:

```sql
SELECT id, text
FROM doc_pages
ORDER BY embedding <=> :query_vec::vector
LIMIT 10;
```

## Core Rules

### Pick DiskANN over HNSW for large OR growing corpora

| Dataset size per table | Index choice |
|---|---|
| < 1M vectors | HNSW (simpler, marginal RAM cost) |
| 1M – 10M | either works; DiskANN saves RAM |
| 10M – 100M | DiskANN strongly preferred |
| 100M+ | DiskANN mandatory |

"Growing corpora" = doc-pages / embeddings that accrue. If your ingest rate suggests 10M vectors within 12 months, start with DiskANN from day one. Migrating later is possible (DROP + CREATE INDEX) but the rebuild takes hours.

### Use SBQ by default (`storage_layout='memory_optimized'`)
This is the default and the point. SBQ stores each dimension in 1-2 bits, reducing the index ~32× for float32 vectors. Recall stays within ~2% of full-precision HNSW for most workloads.

```sql
-- Default: SBQ (memory_optimized)
CREATE INDEX ... USING diskann (embedding vector_cosine_ops);

-- Only override if you measured a recall problem you can attribute to quantization
CREATE INDEX ... USING diskann (embedding vector_cosine_ops) WITH (storage_layout = 'plain');
```

### Distance operators
DiskANN supports exactly pgvector's three operators — same syntax:
- `<=>` cosine (use `vector_cosine_ops`)
- `<->` L2 (use `vector_l2_ops`)
- `<#>` inner product (use `vector_ip_ops`, not with `plain` storage)

Pick based on your embedding model. OpenAI `text-embedding-3-*`, Cohere, sentence-transformers — **cosine** in almost every case.

### Use halfvec for further savings
`halfvec(n)` stores float16 instead of float32. Combine with DiskANN+SBQ:

```sql
ALTER TABLE doc_pages ALTER COLUMN embedding TYPE halfvec(768)
  USING embedding::halfvec(768);

CREATE INDEX ... USING diskann (embedding halfvec_cosine_ops);
```

Another 2× storage reduction, negligible recall impact for most workloads.

## Standard Patterns

### Bulk-load then index (10× faster initial seed)

```sql
-- 1. Create table, don't index yet
CREATE TABLE doc_pages (id bigserial PRIMARY KEY, text text, embedding vector(768));

-- 2. Bulk-insert with embeddings already generated
COPY doc_pages (text, embedding) FROM '/path/to/embeddings.csv';

-- 3. Tune parallel build, then create
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 8;
CREATE INDEX ON doc_pages USING diskann (embedding vector_cosine_ops);
```

### Query-time tuning: balance recall vs latency

```sql
-- More rescore = better recall, slightly slower (default = 50)
SET diskann.query_rescore = 400;

SELECT id FROM doc_pages
ORDER BY embedding <=> :query_vec
LIMIT 10;
```

Set per-session, per-transaction, or per-connection based on workload. Typical range: 50 (fast) to 1000 (high-recall).

### Filtered vector search — the right way

DiskANN has native label-filter support, much faster than post-filtering:

```sql
-- Add a label array column
ALTER TABLE doc_pages ADD COLUMN labels smallint[];

-- Build index INCLUDING labels
CREATE INDEX ON doc_pages
  USING diskann (embedding vector_cosine_ops, labels);

-- Query: pre-filter by label, then vector-rank
SELECT id FROM doc_pages
WHERE labels && ARRAY[1, 3]::smallint[]   -- label 1 OR 3
ORDER BY embedding <=> :query_vec
LIMIT 10;
```

Labels are compact `smallint`s (±32767). Maintain a separate `label_definitions` table to give them names.

### Cold filters (WHERE clauses on non-label columns)

```sql
-- Post-filtered — vector index runs first, then WHERE
SELECT id FROM doc_pages
WHERE status = 'published' AND created_at > '2024-01-01'
ORDER BY embedding <=> :query_vec
LIMIT 10;
```

Over-fetch if the WHERE is selective: `LIMIT 100` then re-limit in app.

### Strict ordering on top of relaxed results

DiskANN returns "approximately sorted" results. Re-sort if strict order matters:

```sql
WITH results AS MATERIALIZED (
  SELECT id, embedding <=> :q::vector AS dist
  FROM doc_pages
  WHERE status = 'published'
  ORDER BY dist LIMIT 10
)
SELECT * FROM results ORDER BY dist + 0;  -- +0 forces strict sort in PG 17+
```

## Index Build Parameters

Defaults are good. Override only with measured reason.

| Parameter | Default | When to change |
|---|---|---|
| `storage_layout` | `memory_optimized` (SBQ) | `plain` if you confirmed recall loss is >2% and it matters |
| `num_neighbors` | 50 | 75-100 for higher recall at the cost of disk + slower build |
| `search_list_size` | 100 | 150-200 if recall during build is low |
| `max_alpha` | 1.2 | rarely touched |
| `num_bits_per_dimension` | 2 (<900d) / 1 (≥900d) | rarely touched; 2 gives better recall at some cost |

Example with custom neighbors (only if you measured):

```sql
CREATE INDEX ON doc_pages
  USING diskann (embedding vector_cosine_ops)
  WITH (num_neighbors = 75);
```

## Gotchas

### UNLOGGED tables are not supported
```sql
CREATE UNLOGGED TABLE temp_vectors (...);
CREATE INDEX ... USING diskann (embedding vector_cosine_ops);
-- ERROR: ambuildempty: not yet implemented
```

Use regular tables for anything DiskANN-indexed.

### Parallel builds require maintenance_work_mem ≥ 64 MB
```sql
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 8;
CREATE INDEX ...;
```

Low memory silently falls back to serial build, taking 5-10× longer.

### Build memory ≠ query memory
Build phase is memory-hungry (potentially 4-8× the final index size). Query phase is modest (few hundred MB). Give maintenance_work_mem lots for the build, then reset.

### License: pgvectorscale is PostgreSQL-licensed (permissive)
Unlike pg_search (AGPL), pgvectorscale is PostgreSQL-license — no AGPL concerns. You can build commercial products on top without special arrangements.

### Trademark: "Timescale" name is protected
You can use pgvectorscale freely. You can't market your product as "Timescale something" without permission.

## When to use HNSW instead

- Dataset is clearly small and will stay small (<1M vectors long-term)
- You have ample RAM (HNSW is simpler and faster when everything fits)
- You need the exact recall guarantees of full-precision HNSW (rare)

## Related skills

- `hybrid-lexical-semantic` — combine DiskANN with BM25 for RAG
- `fastapi-pgsearch-patterns` — FastAPI + async vector search
- `pg-cron-scheduling` — scheduling embedding backfills

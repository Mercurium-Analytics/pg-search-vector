---
name: hybrid-lexical-semantic
description: |
  **Trigger when user asks to:** combine keyword and semantic search, implement RAG retrieval, fuse BM25 with vectors, use reciprocal rank fusion (RRF), or build hybrid search.
  **Keywords:** hybrid search, RRF, reciprocal rank fusion, BM25 + vector, lexical + semantic, pgsv.hybrid_search, RAG retrieval, hybrid retrieval, dense + sparse.
license: MIT
compatibility: Requires pg_search (ParadeDB) + pgvector (+ optionally pgvectorscale) on Postgres 17+.
metadata:
  author: pg-search-vector
---

# Hybrid search: BM25 + pgvector via Reciprocal Rank Fusion

Neither lexical nor semantic search alone is enough for real-world retrieval. BM25 catches exact term matches and rare names that embeddings blur. Vector search catches paraphrases and meaning. Fusing them gives the best of both.

## Golden Path

Use `pgsv.hybrid_search()` (shipped with pg-search-vector) for the standard case:

```sql
-- One call returns fused top-k ids + scores
SELECT h.id, h.rrf_score, d.title, d.body
FROM pgsv.hybrid_search(
       'documents',         -- table
       'id',                -- primary key
       'body',              -- text column (has bm25 index)
       'embedding',         -- vector column (has hnsw or diskann index)
       'robert smith',      -- query text
       '[0.1, 0.2, ...]'::vector, -- query embedding
       10                   -- k
     ) h
JOIN documents d USING (id);
```

You need:
1. A **bm25 index** on `body` (pg_search)
2. A **vector index** (hnsw OR diskann) on `embedding`
3. Both indexes on the same table with a shared primary key

That's it. One function call, one SQL round trip, fused top-k.

## Core Rules

### Reciprocal Rank Fusion (RRF) is the default for good reason

RRF combines two ranked lists into one by summing `1 / (k + rank)` across lists. It's simple, parameter-free, and works well even when the two score distributions (BM25 relevance vs cosine distance) aren't directly comparable.

Constants default: `k = 60` (TREC convention, battle-tested — rarely needs tuning).

Alternatives exist (Borda count, weighted linear combination, learned re-rankers) but RRF is the right default until you have measured recall problems.

### Over-fetch from each arm, then fuse

```sql
-- Fetch top 100 from each arm; fuse; return top 10
SELECT h.id, h.rrf_score FROM pgsv.hybrid_search(
  ..., k => 10, candidate_k => 100
) h;
```

`candidate_k` (default `k * 10`) controls the pool size. Higher = more robust fusion but slower. Typical: `10 * k` is fine.

### Don't weight one side to zero before measuring

Intuition says "semantic is better than keyword for my use case" — usually wrong. BM25 catches proper nouns, codes, acronyms that embeddings smooth over. Run both arms, fuse, and ONLY adjust weights if you have measured recall failures in one side.

## Standard Patterns

### Raw SQL (when pgsv helper isn't available)

```sql
WITH
  lex AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY paradedb.score(id) DESC) AS r
    FROM documents
    WHERE body @@@ 'robert smith'
    LIMIT 100
  ),
  sem AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> :query_vec) AS r
    FROM documents
    ORDER BY embedding <=> :query_vec
    LIMIT 100
  ),
  merged AS (
    SELECT COALESCE(lex.id, sem.id) AS id,
           lex.r AS lex_rank,
           sem.r AS sem_rank,
           COALESCE(1.0::float/(60 + lex.r), 0)
             + COALESCE(1.0::float/(60 + sem.r), 0) AS rrf
    FROM lex FULL OUTER JOIN sem USING (id)
  )
SELECT id, rrf FROM merged ORDER BY rrf DESC LIMIT 10;
```

### Pre-filter by metadata

The cheapest win: filter to a smaller candidate pool BEFORE ranking.

```sql
-- User can only see documents in their tenant — filter first
SELECT h.id, d.title
FROM pgsv.hybrid_search(
  'documents', 'id', 'body', 'embedding',
  'robert', :query_vec::vector, 10
) h
JOIN documents d USING (id)
WHERE d.tenant_id = :tenant_id;
```

This filters AFTER fusion. For true pre-filter pushdown (faster on selective filters), inline the CTE:

```sql
WITH candidates AS (
  SELECT id, body, embedding FROM documents WHERE tenant_id = :tenant_id
)
-- ...hybrid CTEs over candidates instead of documents
```

### Weighted fusion (only when RRF falls short)

If you've measured that lexical quality is reliably better than semantic for your workload (e.g. searching structured names), tilt the scores:

```sql
SELECT id,
       0.7 * COALESCE(1.0::float/(60 + lex.r), 0)    -- 70% lexical weight
     + 0.3 * COALESCE(1.0::float/(60 + sem.r), 0)    -- 30% semantic weight
       AS score
FROM ...
```

Weights in [0, 1], sum to 1.0. Tune using a held-out relevance set, not by feel.

### Re-rank top-K with a cross-encoder (quality at cost)

After hybrid fusion, top 50 can be re-ranked by a cross-encoder model for maximum precision:

```python
# pseudocode — in your app layer
ids = await hybrid_search(..., k=50)
pairs = [(query, row.text) for row in rows]
scores = cross_encoder.predict(pairs)   # BGE-reranker, Cohere rerank, etc.
top10 = sorted(zip(ids, scores), key=lambda x: -x[1])[:10]
```

Adds 100-300ms per query but materially improves precision for RAG applications.

## Choosing the vector index for hybrid

| Vector index | When to use |
|---|---|
| HNSW (pgvector) | <10M rows, RAM-plentiful |
| DiskANN (pgvectorscale) | 10M+ rows, storage-constrained, RAG-at-scale |

For hybrid search, the vector index type doesn't change the fusion logic. Switch freely between HNSW and DiskANN.

## Gotchas

### Both sides must use the SAME primary key
pg_search and pgvector both index by a key column. They must be the same. Use `id bigint/bigserial` as the universal primary key.

### Score NOT comparable between arms
BM25 scores are relative within one index. Cosine distance is absolute. Never compare them directly — that's why RRF uses **ranks**, not raw scores.

### Mismatched corpus freshness
If your embeddings lag behind document updates (embedding pipeline is async), hybrid can return inconsistent results. Patterns:
- Use a `pending_embedding` boolean on the row; exclude from vector arm until embedded
- Or run BM25-only for rows without embeddings (graceful degradation)

### Empty query text
`@@@ ''` matches nothing. If query_text is empty, fall through to vector-only:

```sql
IF query_text = '' THEN
  -- vector only
ELSIF query_vec IS NULL THEN
  -- bm25 only
ELSE
  -- hybrid
END IF;
```

`pgsv.hybrid_search()` handles all three cases automatically.

### Vector query cost dominates at scale
BM25 query: ~1-10ms on millions of rows. Vector query: 5-50ms. At 100M+ vectors with HNSW, vector arm becomes the bottleneck — move to DiskANN.

## Client-side result shaping

### Expose scores to the app, not just IDs

Your API should return both `lex_score` and `sem_score` so the frontend can:
- Show a "why this result?" affordance
- A/B test re-ranking strategies
- Debug recall issues

```python
# FastAPI response model
class HybridHit(BaseModel):
    id: int
    title: str
    lex_rank: int | None
    sem_rank: int | None
    rrf_score: float
```

### Cache query embeddings
The same user query embedding may be searched multiple times (pagination, filter changes). Cache in Redis by hash(query_text):

```python
key = f"emb:{model}:{hashlib.sha1(query.encode()).hexdigest()}"
vec = await redis.get(key) or await embed(query)
```

## Related skills

- `pg-search-bm25` — the lexical half
- `pgvectorscale-diskann` — the semantic half at scale
- `fastapi-pgsearch-patterns` / `django-pgsearch-patterns` — framework integration

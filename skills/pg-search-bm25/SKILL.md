---
name: pg-search-bm25
description: |
  **Trigger when user asks to:** add full-text search, BM25, relevance-ranked search, autocomplete, typo tolerance, phrase matching, or replace Elasticsearch with Postgres.
  **Keywords:** pg_search, ParadeDB, BM25, @@@, Tantivy, full-text search, bm25 index, paradedb.score, paradedb.snippet, tokenizer, ngram, fuzzy, autocomplete, phrase prefix, typo tolerance.
license: MIT
compatibility: Requires PostgreSQL 15+ with the pg_search extension (ParadeDB 0.20+).
metadata:
  author: pg-search-vector
---

# pg_search: BM25 full-text search in Postgres

pg_search is a Rust extension by ParadeDB that embeds **Tantivy** (a Lucene-family search engine) as a native Postgres index type. You get Elasticsearch-quality BM25 ranking, phrase queries, fuzzy match, and regex — via SQL, in the same database, transactionally consistent with the rest of your data.

## Golden Path

For a typical searchable text column:

```sql
CREATE EXTENSION IF NOT EXISTS pg_search;

-- Minimum-viable BM25 index
CREATE INDEX articles_bm25 ON articles
  USING bm25 (id, title, body)
  WITH (key_field='id');

-- Query
SELECT id, title
FROM articles
WHERE title @@@ 'robert'        -- the match operator
ORDER BY paradedb.score(id) DESC  -- BM25 relevance
LIMIT 10;
```

Three choices worth making explicitly:

1. **`key_field`** must be a unique non-null column (`id` by default). pg_search uses it to identify rows.
2. **Columns inside the index** are included for scoring. Anything you want to search must be listed in `(id, title, body, …)`.
3. **Use `@@@`**, not `~*` or `ILIKE`. `@@@` is the pg_search match operator — it hits the BM25 index.

## Core Rules

### Always name the index explicitly
```sql
CREATE INDEX articles_bm25 ON articles
  USING bm25 (id, title, body) WITH (key_field='id');
```
Not `CREATE INDEX ON articles USING bm25 (...)` — anonymous indexes are painful to reindex or drop during migrations.

### Include ONLY what you search
Don't throw every column into the index "just in case". Every field inflates disk + write amplification.

```sql
-- BAD: 15 columns, most never searched
CREATE INDEX ... USING bm25 (id, title, body, author, created_at, updated_at, status, tags, ...);

-- GOOD: just the text
CREATE INDEX ... USING bm25 (id, title, body);
```

Filter columns (status, created_at) belong in normal btree indexes OR included via `INCLUDE` for covering scans.

### Search with `@@@`, rank with `paradedb.score()`, paginate with `LIMIT`

```sql
SELECT id, title, paradedb.score(id) AS rank
FROM articles
WHERE body @@@ 'robert smith'
ORDER BY rank DESC
LIMIT 20 OFFSET 0;
```

`ORDER BY paradedb.score(id) DESC LIMIT k` enables top-k optimizations (Block-Max WAND). Without LIMIT, scoring is still correct but slower.

### Never call `paradedb.score()` without the matching `@@@`
The score function requires the row to have come through the bm25 index scan. If you filter on something else, `paradedb.score()` returns `NULL`.

## Standard Patterns

### Multi-field search with per-field boosting

```sql
-- Title matches weight 5×, body matches weight 1×
SELECT id, title
FROM articles
WHERE id @@@ paradedb.boolean(
  should => ARRAY[
    paradedb.parse('title:(robert smith)^5.0'),
    paradedb.parse('body:(robert smith)^1.0')
  ]
)
ORDER BY paradedb.score(id) DESC
LIMIT 10;
```

### Phrase queries

```sql
-- Exact phrase "robert smith" (tokens adjacent, in order)
SELECT id FROM articles
WHERE body @@@ paradedb.phrase('body', ARRAY['robert', 'smith'])
ORDER BY paradedb.score(id) DESC
LIMIT 10;
```

### Typo-tolerant / fuzzy match

```sql
-- Levenshtein distance = 1 (one insertion, deletion, or substitution)
SELECT id FROM articles
WHERE body @@@ paradedb.match('body', 'mercuriu', distance => 1)
ORDER BY paradedb.score(id) DESC
LIMIT 10;
```

### Combined with regular SQL filters

```sql
SELECT id, title
FROM articles
WHERE body @@@ 'robert'
  AND status = 'published'          -- normal btree filter
  AND created_at > '2024-01-01'
ORDER BY paradedb.score(id) DESC
LIMIT 10;
```

Predicates outside `@@@` are post-filters. If your search result set is large and the filter is selective, consider adding status/created_at into the bm25 index as `fast_fields` for pushed-down filtering.

### Highlighting matches

```sql
SELECT
  id,
  title,
  paradedb.snippet(body, start_tag => '<mark>', end_tag => '</mark>') AS highlight
FROM articles
WHERE body @@@ 'robert'
LIMIT 10;
```

Returns body excerpts with `<mark>...</mark>` around matching terms. Useful for RAG and search UIs.

## Tokenizer Rules

Default tokenizer lowercases + splits on whitespace/punctuation. For autocomplete, prefixes, substrings, or non-English text, pick a tokenizer at index creation:

```sql
-- Autocomplete: prefix-only ngram (2-5 chars, prefix side only)
CREATE INDEX articles_name_bm25 ON articles
  USING bm25 (id, name)
  WITH (
    key_field='id',
    text_fields='{"name": {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": true}}}'
  );

-- Substring match anywhere: full ngram
CREATE INDEX ... WITH (text_fields='{"name": {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5}}}');

-- English with stemming + stop words: use default or a language-specific tokenizer
CREATE INDEX ... WITH (text_fields='{"body": {"tokenizer": {"type": "default"}, "stemmer": "english"}}');

-- Source code: preserves camelCase, snake_case, identifiers
CREATE INDEX ... WITH (text_fields='{"body": {"tokenizer": {"type": "source_code"}}}');
```

See the companion **bm25-tokenizer-guide** skill for a decision tree.

## Gotchas

### Writes cost more
Every INSERT/UPDATE/DELETE on a row updates the bm25 index. For batch imports, create the index **after** the bulk load:

```sql
-- 100× faster for initial seed
COPY articles FROM '/path/to/data.csv';
CREATE INDEX articles_bm25 ON articles USING bm25 (id, title, body) WITH (key_field='id');
```

### Rebuilding is expensive at scale
A bm25 index on 100M rows takes several hours to build. Plan schema migrations accordingly. Use `REINDEX CONCURRENTLY` when possible.

### Memory limit governs the memtable
`pg_search.memory_limit` (default 2 GB) is the cap on the shared in-memory write buffer. If you ingest heavily, the memtable spills to disk; under-sizing causes slow writes. Tune via:

```sql
ALTER SYSTEM SET pg_search.memory_limit = '1GB';  -- or whatever fits your RAM budget
SELECT pg_reload_conf();
```

### `@@@` does NOT match empty strings or NULL
`WHERE body @@@ ''` returns no rows. Check for empty query in your app layer.

### shared_preload_libraries required
`pg_search` MUST be in `shared_preload_libraries`. `CREATE EXTENSION pg_search` fails otherwise. Fresh installs of the `pg-search-vector` image handle this automatically.

### Large result sets + ORDER BY score
For large `LIMIT` values (>1000), Block-Max WAND's effectiveness drops. If you need pagination beyond 1k rows, consider cursor-based pagination (`WHERE id > last_id`) rather than OFFSET.

### Keep `_source` small
pg_search stores a Tantivy copy of every field listed in the index definition. Don't include large `TEXT` blobs (>10 KB) if you don't need them for scoring — index the fact that they're there via a hash, and SELECT the blob from the heap.

## When NOT to use pg_search

- **Very small datasets** (<10k rows): `ILIKE` + a btree `text_pattern_ops` index is simpler.
- **Exact prefix lookups only, no ranking**: btree `text_pattern_ops` is cheaper.
- **Queries where BM25 ranking is wrong** — e.g. you want exact field equality, not relevance. Use `WHERE field = 'exact'`.
- **Extremely high-write tables where search is optional**: the write amplification may not be worth it. Push search to a replica.

## Related skills

- `bm25-tokenizer-guide` — tokenizer decision tree
- `hybrid-lexical-semantic` — combine BM25 with pgvector similarity
- `django-pgsearch-patterns` / `fastapi-pgsearch-patterns` — framework integration
- `pg-repack-runbook` — when bm25 index bloat appears

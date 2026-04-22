---
name: bm25-tokenizer-guide
description: |
  **Trigger when user asks to:** choose a pg_search tokenizer, set up autocomplete vs substring vs natural-language search, use ngram, configure Tantivy tokenizers, or debug bm25 index size.
  **Keywords:** pg_search tokenizer, Tantivy tokenizer, ngram, source_code, prefix_only, pgsv.bm25_preset, pgsv.bm25_create_index, text_fields, autocomplete tokenizer, substring match, stemmer.
license: MIT
compatibility: pg_search 0.20+.
metadata:
  author: pg-search-vector
---

# BM25 tokenizer decision tree

The tokenizer decides how text becomes searchable tokens. Pick wrong and you get no hits ("par" matches nothing because the default tokenized "partech" as `["partech"]`). Pick too aggressive (ngram over every field) and your index explodes to 10× its useful size.

## Golden Path

Use the **`pgsv.bm25_create_index()`** procedure (shipped with pg-search-vector) if you don't want to think about it:

```sql
CALL pgsv.bm25_create_index(
  'items_name_bm25',   -- index name
  'items',             -- table
  'id',                -- key_field (PK)
  'name',              -- text field
  'autocomplete'       -- preset
);
```

> You can't write `text_fields=pgsv.bm25_preset('autocomplete')` directly in a
> `CREATE INDEX … WITH (...)` — Postgres's reloption parser doesn't evaluate
> function calls and passes the raw token to ParadeDB, which then fails to
> parse it as JSON. `bm25_create_index` composes the DDL server-side via
> `EXECUTE format()` so the preset's JSON is baked in as a literal.

Preset options:
- `'autocomplete'` — prefix-only ngram (2-5 chars). For typing into a search box.
- `'substring'` — full ngram (2-5 chars). Match anywhere in a string.
- `'natural'` — default tokenizer. English prose, phrases, stemming optional.
- `'code'` — source-code tokenizer. Preserves camelCase, snake_case, identifiers.

## Core Rules

### One tokenizer per field, per workload

You usually want different tokenizers for different fields:
- `name` — autocomplete (user types a fragment, expects matches)
- `description` — natural (full-text query)
- `filename` — substring (match partial names)

Index each with its own tokenizer:

```sql
CREATE INDEX items_bm25 ON items
  USING bm25 (id, name, description, filename)
  WITH (
    key_field='id',
    text_fields='{
      "name":        {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": true}},
      "description": {"tokenizer": {"type": "default"}, "stemmer": "english"},
      "filename":    {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5}}
    }'
  );
```

### Index size grows with token count

Ngram tokenizers explode index size:
- Default tokenizer: 1 token per word
- Prefix-only ngram (2-5): 4 tokens per word ("mercurium" → "me", "mer", "merc", "mercu")
- Full ngram (2-5): 20+ tokens per word (every substring)

For short fields (names) this is fine. For long fields (document bodies), ngram is too expensive.

### Prefix-only ngram is your best default for names

```
"mercurium" under prefix-only (2, 5):
  ["me", "mer", "merc", "mercu"]
```

Hits anything starting with `m`, `me`, `mer`, `merc`, `mercu`. Typical user search. Compact.

Full ngram would also include `"er", "erc", "rcu"...` — matches substrings anywhere but bloats 5× more.

## Decision tree

```
Is the field "prose" (paragraphs, sentences)?
├── YES → default tokenizer (+ optional stemmer)
│         text_fields='{"body": {"tokenizer": {"type":"default"}, "stemmer":"english"}}'
└── NO → is it a short string (name, title, code)?
    ├── YES → do users type partial prefixes?
    │   ├── YES → prefix-only ngram (preset: 'autocomplete')
    │   │       CALL pgsv.bm25_create_index(..., 'autocomplete')
    │   └── NO (they know the exact token) → default tokenizer
    │           text_fields='{"name": {"tokenizer": {"type":"default"}}}'
    └── NO (source code, identifiers, camelCase) → source_code tokenizer
            text_fields='{"code": {"tokenizer": {"type":"source_code"}}}'
```

## Tokenizer reference

### `default`
- Lowercases, splits on whitespace + punctuation
- Best for: English prose, titles, descriptions
- Token count: ~1 per word
- Index size: smallest

```sql
text_fields='{"body": {"tokenizer": {"type": "default"}}}'
```

Query behavior:
```
"The quick brown fox" → ["the", "quick", "brown", "fox"]
Query "quick" matches ✓
Query "quic" matches ✗
```

### `ngram` with `prefix_only: true` (autocomplete)
- Generates prefixes of lengths `min_gram` to `max_gram`
- Best for: autocomplete on names, codes, titles
- Token count: ~(max_gram - min_gram + 1) per word

```sql
text_fields='{"name": {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": true}}}'
```

Query behavior:
```
"mercurium" → ["me", "mer", "merc", "mercu"]
Query "me" matches ✓
Query "mer" matches ✓
Query "merc" matches ✓
Query "urium" matches ✗   (not a prefix)
```

### `ngram` with `prefix_only: false` (substring)
- Generates all substrings of lengths min_gram to max_gram
- Best for: substring-anywhere search
- Token count: ~5-20× per word (explodes)

```sql
text_fields='{"filename": {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5}}}'
```

Query behavior:
```
"mercurium" → ["me", "mer", "erc", "rcu", "cur"...]
Query "cur" matches ✓
```

**Cost**: index is ~5-10× bigger than prefix-only. Only use for fields where substring anywhere-in-string match is genuinely required.

### `source_code`
- Splits on camelCase, snake_case, dots, preserves identifiers
- Best for: code search, tag lookups, any "typed identifier" content

```sql
text_fields='{"code": {"tokenizer": {"type": "source_code"}}}'
```

Query behavior:
```
"getUserById" → ["get", "user", "by", "id", "getUserById"]
"parse_json"  → ["parse", "json", "parse_json"]
"MyApp.Config" → ["MyApp", "Config", "MyApp.Config"]
```

### Language-specific (via `stemmer`)
Stemmer reduces words to roots: "running" → "run".

```sql
text_fields='{"body": {"tokenizer": {"type": "default"}, "stemmer": "english"}}'
```

Supported stemmers: english, french, german, spanish, italian, portuguese, russian, dutch, swedish, norwegian, danish, finnish, hungarian, romanian, tamil, turkish, arabic, greek.

Trade-off: "organize" matches "organizing" (good for full-text), but "Microsoft" also stems weirdly ("microsoft" → "microsoft" is fine; proper nouns usually are).

## Standard Patterns

### Autocomplete name field + natural description

```sql
CREATE INDEX companies_bm25 ON companies
  USING bm25 (id, name, description)
  WITH (
    key_field='id',
    text_fields='{
      "name": {"tokenizer": {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": true}, "fast": true},
      "description": {"tokenizer": {"type": "default"}, "stemmer": "english"}
    }'
  );

-- Autocomplete query (user typed "merc")
SELECT id, name FROM companies
WHERE name @@@ 'merc'
ORDER BY paradedb.score(id) DESC LIMIT 10;

-- Full-text search on description
SELECT id, name FROM companies
WHERE description @@@ 'software platform for compliance'
ORDER BY paradedb.score(id) DESC LIMIT 10;
```

### Multilingual table via partial indexes

```sql
-- Separate bm25 index per language
CREATE INDEX docs_en_bm25 ON documents
  USING bm25 (id, text) WITH (key_field='id', text_fields='{"text": {"tokenizer": {"type":"default"}, "stemmer":"english"}}')
  WHERE lang = 'en';

CREATE INDEX docs_fr_bm25 ON documents
  USING bm25 (id, text) WITH (key_field='id', text_fields='{"text": {"tokenizer": {"type":"default"}, "stemmer":"french"}}')
  WHERE lang = 'fr';

-- Query targets the right index
SELECT id FROM documents WHERE lang = 'en' AND text @@@ 'running';
SELECT id FROM documents WHERE lang = 'fr' AND text @@@ 'courir';
```

### `fast` field for filter pushdown

Adding `"fast": true` on a field stores it in a columnar format inside the index — filterable + sortable without heap access. Good for filter/facet fields:

```sql
text_fields='{
  "name": {"tokenizer": {"type": "ngram", ...}, "fast": true},
  "status": {"fast": true}
}'
```

Now `WHERE name @@@ 'merc' AND status = 'active'` pushes status filter INTO the bm25 scan, skipping inactive rows before ranking.

## Gotchas

### Changing tokenizer requires full reindex
Tokenizer is fixed at index creation. To change, `DROP INDEX` + `CREATE INDEX` with new config. On large tables, that's hours. Get it right the first time.

### `min_gram` below 2 creates cruft
`min_gram=1` adds every single letter: "m", "e", "r"... creating millions of useless hits. Keep min_gram ≥ 2.

### `max_gram` above 5 diminishes returns
After 5 chars, prefix-match is already narrow. Going higher just adds tokens. 2-5 is the standard sweet spot.

### Language stemmers aren't free
Stemmers add per-token overhead during indexing + query. For small tables, imperceptible. For ingestion at 10k rows/s, stemmers slow writes ~20%. Measure if it matters.

### Accent handling
Default tokenizer does NOT fold accents. "café" and "cafe" are different tokens. Add `"asciifolding": true` in the text_field config to collapse accents:

```sql
text_fields='{"name": {"tokenizer": {"type":"default"}, "asciifolding": true}}'
```

### Case sensitivity
Default tokenizer lowercases. `source_code` preserves case. Source code search for `getUserById` with lowercase `"getuserbyid"` won't match under source_code tokenizer — search case-sensitively or index with an additional lowercase field.

## Measuring index size

```sql
SELECT
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```

Rough targets:
- Default tokenizer on English text: ~20% of the raw column size
- Prefix-only ngram on names: ~80% of the column size
- Full ngram on names: ~4× the column size
- Full ngram on long fields: DON'T — you'll regret it

## Related skills

- `pg-search-bm25` — core BM25 operations
- `hybrid-lexical-semantic` — combining BM25 with vectors
- `pg-repack-runbook` — reclaim space when bm25 indexes bloat

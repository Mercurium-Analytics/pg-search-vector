-- pgsv: convenience layer on top of pg_search + pgvector.
--
-- Provides:
--   pgsv.bm25_preset(name)           — named tokenizer presets (returns JSON)
--   pgsv.bm25_create_index(...)      — create a BM25 index with a preset
--   pgsv.hybrid_search(...)          — one-shot lexical + semantic RRF search
--
-- Loaded automatically on first container init via /docker-entrypoint-initdb.d.
-- Safe to re-run: all objects use CREATE OR REPLACE / IF NOT EXISTS.

CREATE SCHEMA IF NOT EXISTS pgsv;


-- ─────────────────────────────────────────────────────────────────────
-- Tokenizer presets
-- ─────────────────────────────────────────────────────────────────────
-- Return a text_fields JSON blob suitable for
--   CREATE INDEX ... USING bm25 (...) WITH (text_fields=pgsv.bm25_preset('autocomplete'))
--
-- Presets:
--   'autocomplete'   prefix-only ngram (2..5) — typeahead on names, codes
--   'substring'      full ngram (2..5)        — match anywhere in a string
--   'natural'        default tokenizer        — prose, phrases, full words
--   'code'           source_code tokenizer    — identifiers, camelCase, snake_case
--
-- IMPORTANT: Postgres's `WITH (...)` reloption parser does NOT evaluate
-- function calls — it captures the source token literally. That means
--   CREATE INDEX ... WITH (text_fields=pgsv.bm25_preset('autocomplete'))
-- FAILS with "expected value" because ParadeDB receives the literal token
-- "pgsv.bm25_preset(...)" and can't parse it as JSON.
--
-- Use pgsv.bm25_create_index(...) (below), or compose via `EXECUTE format()`
-- yourself. Direct SELECTs of the function work fine.
CREATE OR REPLACE FUNCTION pgsv.bm25_preset(preset text, field_name text DEFAULT 'name')
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  tok jsonb;
BEGIN
  tok := CASE preset
    WHEN 'autocomplete' THEN
      jsonb_build_object('type','ngram','min_gram',2,'max_gram',5,'prefix_only',true)
    WHEN 'substring' THEN
      jsonb_build_object('type','ngram','min_gram',2,'max_gram',5,'prefix_only',false)
    WHEN 'natural' THEN
      jsonb_build_object('type','default')
    WHEN 'code' THEN
      jsonb_build_object('type','source_code')
    ELSE
      NULL
  END;
  IF tok IS NULL THEN
    RAISE EXCEPTION 'pgsv.bm25_preset: unknown preset %. Valid: autocomplete, substring, natural, code', preset;
  END IF;
  RETURN jsonb_build_object(
    field_name,
    jsonb_build_object('tokenizer', tok, 'fast', true)
  )::text;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────
-- Create a BM25 index with a named tokenizer preset
-- ─────────────────────────────────────────────────────────────────────
-- Composes the full CREATE INDEX DDL server-side via EXECUTE format() so
-- the preset JSON is baked in as a literal (see the note on bm25_preset
-- for why inline function calls in WITH () don't work).
--
-- Usage:
--   CALL pgsv.bm25_create_index(
--          'items_bm25',        -- index name
--          'items',             -- table (schema-qualified OK)
--          'id',                -- key_field (must be the PK)
--          'name',              -- text field to index
--          'autocomplete');     -- preset: autocomplete|substring|natural|code
CREATE OR REPLACE PROCEDURE pgsv.bm25_create_index(
  index_name text,
  table_name text,
  key_field  text,
  text_field text,
  preset     text DEFAULT 'natural'
) LANGUAGE plpgsql AS $$
DECLARE
  qualified_table text := table_name::regclass::text;
  stmt text;
BEGIN
  stmt := format(
    'CREATE INDEX %I ON %s USING bm25 (%I, %I) WITH (key_field=%L, text_fields=%L)',
    index_name, qualified_table, key_field, text_field,
    key_field, pgsv.bm25_preset(preset, text_field)
  );
  EXECUTE stmt;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────
-- Hybrid search: BM25 lexical + pgvector semantic, fused with RRF
-- ─────────────────────────────────────────────────────────────────────
-- Returns top k rows with lex_rank, sem_rank, and rrf score.
-- Callers filter/join back to their table by id.
--
-- Arguments:
--   table_name   fully qualified (schema.table) or unqualified
--   id_col       name of integer/bigint PK (used in index `key_field`)
--   text_col     name of text column with bm25 index
--   vector_col   name of vector column with hnsw/ivfflat index
--   query_text   search string (empty string skips lexical)
--   query_vec    vector literal (NULL skips semantic)
--   k            top k (default 10)
--   rrf_k        RRF constant (default 60 per TREC convention)
--   candidate_k  per-branch candidate pool size (default k*10)
--
-- Example:
--   SELECT h.*, c.name
--   FROM pgsv.hybrid_search(
--          'documents', 'id', 'name', NULL,
--          'robert', NULL, 10) h
--   JOIN documents c USING (id);
CREATE OR REPLACE FUNCTION pgsv.hybrid_search(
  table_name   text,
  id_col       text,
  text_col     text,
  vector_col   text,
  query_text   text,
  query_vec    vector,
  k            int DEFAULT 10,
  rrf_k        int DEFAULT 60,
  candidate_k  int DEFAULT NULL
)
RETURNS TABLE (
  id         bigint,
  lex_rank   bigint,
  sem_rank   bigint,
  rrf_score  double precision
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cand_k int := COALESCE(candidate_k, k * 10);
  has_lex boolean := query_text IS NOT NULL AND length(btrim(query_text)) > 0;
  has_sem boolean := query_vec IS NOT NULL AND vector_col IS NOT NULL AND length(vector_col) > 0;
  -- Resolving the table through regclass both validates that it exists and
  -- returns a safely-quoted identifier, so we can interpolate with %s below
  -- without opening an injection surface when callers pass schema-qualified names.
  qualified_table text := table_name::regclass::text;
  sql text;
BEGIN
  IF k <= 0 THEN
    RAISE EXCEPTION 'pgsv.hybrid_search: k must be > 0 (got %)', k;
  END IF;
  IF cand_k <= 0 THEN
    RAISE EXCEPTION 'pgsv.hybrid_search: candidate_k must be > 0 (got %)', cand_k;
  END IF;
  IF NOT has_lex AND NOT has_sem THEN
    RAISE EXCEPTION 'pgsv.hybrid_search: at least one of query_text or query_vec must be provided';
  END IF;

  sql := format($fmt$
    WITH
    lex AS (
      %s
    ),
    sem AS (
      %s
    ),
    merged AS (
      SELECT COALESCE(lex.id, sem.id) AS id,
             lex.r AS lex_rank,
             sem.r AS sem_rank,
             COALESCE(1.0::float / (%s + lex.r)::float, 0) + COALESCE(1.0::float / (%s + sem.r)::float, 0) AS rrf
      FROM lex FULL OUTER JOIN sem USING (id)
    )
    SELECT id, lex_rank, sem_rank, rrf
    FROM merged
    ORDER BY rrf DESC
    LIMIT %s
    $fmt$,
    CASE WHEN has_lex THEN
      format(
        'SELECT %I::bigint AS id, ROW_NUMBER() OVER (ORDER BY paradedb.score(%I) DESC) AS r
         FROM %s WHERE %I @@@ %L LIMIT %s',
        id_col, id_col, qualified_table, text_col, query_text, cand_k
      )
    ELSE
      'SELECT NULL::bigint AS id, NULL::bigint AS r WHERE FALSE'
    END,
    CASE WHEN has_sem THEN
      format(
        'SELECT %I::bigint AS id, ROW_NUMBER() OVER (ORDER BY %I <=> %L::vector) AS r
         FROM %s WHERE %I IS NOT NULL ORDER BY %I <=> %L::vector LIMIT %s',
        id_col, vector_col, query_vec::text, qualified_table, vector_col, vector_col, query_vec::text, cand_k
      )
    ELSE
      'SELECT NULL::bigint AS id, NULL::bigint AS r WHERE FALSE'
    END,
    rrf_k, rrf_k, k
  );

  RETURN QUERY EXECUTE sql;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────
-- Version stamp
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW pgsv.version AS
SELECT '0.2.0'::text AS pgsv,
       (SELECT extversion FROM pg_extension WHERE extname='pg_search') AS pg_search,
       (SELECT extversion FROM pg_extension WHERE extname='vector')    AS pgvector;

COMMENT ON SCHEMA pgsv IS
  'pg-search-vector: hybrid lexical (pg_search BM25) + semantic (pgvector) search helpers';

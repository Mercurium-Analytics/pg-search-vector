"""Django adapter for pg-search-vector.

Exposes:
  BM25            — annotation for lexical score (pair with `<field>__bm25=` filter)
  bm25_index_sql  — DDL helper for `migrations.RunSQL` (JSON baked in as literal)
  hybrid_search   — high-level helper that auto-embeds via a configured provider
  get_embedder    — access the configured embedder (ollama / openai / mercuriumai / custom)
  name__bm25      — lookup: Model.objects.filter(name__bm25='robert')

All expressions emit pg_search / pgvector SQL that runs natively in Postgres.
"""
default_app_config = "pgsv.apps.PgsvConfig"

from .ddl import bm25_index_sql
from .expressions import BM25
from .search import hybrid_search, HybridHit
from .embedders import get_embedder, Embedder

__all__ = [
    "BM25",
    "bm25_index_sql",
    "hybrid_search", "HybridHit",
    "get_embedder", "Embedder",
]
__version__ = "0.2.0"

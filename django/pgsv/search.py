"""High-level hybrid_search() helper.

Given a Django model and a query string, it:
  1. embeds the query via the configured provider
  2. calls pgsv.hybrid_search() in Postgres
  3. returns rows with (id, lex_rank, sem_rank, rrf_score)

Use this when you want the shortest path from "user typed a string" to
"ranked results". For full control, use pgsv.expressions.HybridSearch
inside a QuerySet or call the Postgres function directly via a cursor.
"""
from dataclasses import dataclass
from typing import Any, List, Optional, Sequence, Type

from django.db import connection, models

from . import conf
from .embedders import Embedder, get_embedder


@dataclass
class HybridHit:
    id: int
    lex_rank: Optional[int]
    sem_rank: Optional[int]
    rrf_score: float


def hybrid_search(
    model: Type[models.Model],
    query_text: str,
    *,
    text_field: str,
    vector_field: str,
    k: int = 10,
    id_field: str = "id",
    query_vec: Optional[Sequence[float]] = None,
    embedder: Optional[Embedder] = None,
    rrf_k: Optional[int] = None,
    candidate_k: Optional[int] = None,
) -> List[HybridHit]:
    """Run BM25 + vector + RRF against `model`.

    - If `query_vec` is None AND an embedder is configured, the query is
      auto-embedded. Pass `query_vec=[]` to force lexical-only.
    - Returns a list of HybridHit. Join back to the model with
      ``model.objects.filter(pk__in=[h.id for h in hits])`` if you need rows.
    """
    cfg = conf.get_settings()
    table = model._meta.db_table
    rrf_k = rrf_k if rrf_k is not None else cfg["RRF_K"]
    candidate_k = candidate_k if candidate_k is not None else cfg["CANDIDATE_K"]

    vec_param = None
    if query_vec is None:
        emb = embedder or get_embedder() if cfg.get("EMBEDDING_PROVIDER") else None
        if emb is not None:
            vec_param = _vec_literal(emb.embed(query_text))
    elif len(query_vec) > 0:
        vec_param = _vec_literal(query_vec)

    sql = """
        SELECT id, lex_rank, sem_rank, rrf_score
        FROM pgsv.hybrid_search(
            %s, %s, %s, %s,
            %s, %s::vector, %s, %s, %s
        )
    """
    params = [
        table, id_field, text_field, vector_field,
        query_text, vec_param, k, rrf_k, candidate_k,
    ]
    with connection.cursor() as cur:
        cur.execute(sql, params)
        return [HybridHit(*row) for row in cur.fetchall()]


def _vec_literal(vec: Sequence[float]) -> str:
    """Format a float sequence as a pgvector literal: '[1.0,2.0,...]'."""
    return "[" + ",".join(f"{float(x):.8f}" for x in vec) + "]"

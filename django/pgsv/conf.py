"""Reads Django settings.PGSV with defaults."""
from django.conf import settings


_DEFAULTS = {
    "EMBEDDING_PROVIDER": None,
    "EMBEDDING_MODEL": None,
    "EMBEDDING_DIM": None,
    "EMBEDDING_KWARGS": {},
    "RRF_K": 60,
    "CANDIDATE_K": None,
    "QUERY_TIMEOUT_MS": 500,
    "CACHE_QUERY_EMBEDDINGS": False,
    "CACHE_TTL_SECONDS": 300,
}


def get_settings() -> dict:
    user = getattr(settings, "PGSV", {}) or {}
    merged = dict(_DEFAULTS)
    merged.update(user)
    return merged

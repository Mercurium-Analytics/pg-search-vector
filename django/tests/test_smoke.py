"""Smoke tests that don't require a running database.

For integration tests against a live Postgres with pg-search-vector loaded,
add your own fixture using the image:

    docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres \\
      ghcr.io/mercurium-analytics/pg-search-vector:pg17
"""
import pytest


def test_package_imports():
    import pgsv
    assert hasattr(pgsv, "BM25")
    assert hasattr(pgsv, "HybridSearch")
    assert hasattr(pgsv, "hybrid_search")


def test_embedder_registry_lists_builtins():
    from pgsv.embedders.registry import _ALIASES
    assert {"ollama", "openai", "mercuriumai", "custom"} <= set(_ALIASES)


def test_ollama_embedder_signature():
    from pgsv.embedders.ollama import OllamaEmbedder
    emb = OllamaEmbedder(model="nomic-embed-text", base_url="http://localhost:11434")
    assert emb.model == "nomic-embed-text"
    assert emb.base_url == "http://localhost:11434"


def test_mercuriumai_embedder_signature():
    from pgsv.embedders.mercuriumai import MercuriumAIEmbedder
    emb = MercuriumAIEmbedder(
        model="nomic-embed-text",
        base_url="https://inference.example.com",
    )
    assert emb.base_url == "https://inference.example.com"
    assert emb.path.startswith("/")


def test_missing_embedder_provider_raises():
    from pgsv.embedders.registry import _build
    with pytest.raises(ValueError):
        _build("unknown-provider-xyz")

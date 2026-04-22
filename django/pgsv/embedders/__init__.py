"""Pluggable query-embedding providers.

Pick one via settings.PGSV["EMBEDDING_PROVIDER"]:
  - "ollama"       → OllamaEmbedder (direct HTTP to an Ollama server)
  - "openai"       → OpenAIEmbedder (uses the openai SDK)
  - "mercuriumai"  → MercuriumAIEmbedder (uses utils.ai_models.mercuriumai)
  - "custom"       → CustomEmbedder (wraps a user callable)

All embedders expose a single method: ``embed(text: str) -> list[float]``.
"""
from .base import Embedder
from .registry import get_embedder

__all__ = ["Embedder", "get_embedder"]

"""OpenAI embedder (or any OpenAI-compatible endpoint)."""
from typing import List

from .base import Embedder


class OpenAIEmbedder(Embedder):
    """Uses the official openai SDK. Set base_url for compatible providers."""

    def __init__(self, model: str = "text-embedding-3-small",
                 api_key: str | None = None,
                 base_url: str | None = None,
                 dim: int = 0):
        try:
            from openai import OpenAI
        except ImportError as e:
            raise ImportError(
                "OpenAIEmbedder requires `openai`. Install with "
                "`pip install pg-search-vector-django[openai]`"
            ) from e
        kwargs = {}
        if api_key:
            kwargs["api_key"] = api_key
        if base_url:
            kwargs["base_url"] = base_url
        self.client = OpenAI(**kwargs)
        self.model = model
        self.dim = dim

    def embed(self, text: str) -> List[float]:
        r = self.client.embeddings.create(model=self.model, input=text)
        return r.data[0].embedding

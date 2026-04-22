"""Direct HTTP embedder for a local/remote Ollama server."""
from typing import List

import requests

from .base import Embedder


class OllamaEmbedder(Embedder):
    """POST {base_url}/api/embeddings  body={"model": ..., "prompt": text}."""

    def __init__(self, model: str, base_url: str = "http://ollama:11434",
                 dim: int = 0, timeout: float = 2.0):
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.dim = dim
        self.timeout = timeout

    def embed(self, text: str) -> List[float]:
        r = requests.post(
            f"{self.base_url}/api/embeddings",
            json={"model": self.model, "prompt": text},
            timeout=self.timeout,
        )
        r.raise_for_status()
        return r.json()["embedding"]

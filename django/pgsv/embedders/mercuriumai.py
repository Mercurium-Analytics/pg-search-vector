
from typing import List, Optional

import requests

from .base import Embedder


class MercuriumAIEmbedder(Embedder):
    """HTTP embedder against an Ollama-compatible JSON endpoint."""

    def __init__(
        self,
        model: str,
        base_url: str,
        dim: int = 0,
        timeout: float = 5.0,
        api_key: Optional[str] = None,
        path: str = "/embeddings/api/private_embeddings",
    ):
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.path = path if path.startswith("/") else f"/{path}"
        self.dim = dim
        self.timeout = timeout
        self.api_key = api_key

    def embed(self, text: str) -> List[float]:
        headers = {}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        r = requests.post(
            f"{self.base_url}{self.path}",
            json={"model": self.model, "prompt": text},
            headers=headers,
            timeout=self.timeout,
        )
        r.raise_for_status()
        resp = r.json()
        if "embedding" in resp:
            return resp["embedding"]
        if "embeddings" in resp:
            first = resp["embeddings"][0]
            return first["embedding"] if isinstance(first, dict) else first
        raise ValueError(f"Unexpected embedding payload: keys={list(resp)}")

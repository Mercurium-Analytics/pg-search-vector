"""Custom embedder: wraps any callable (text) -> list[float]."""
from typing import Callable, List

from .base import Embedder


class CustomEmbedder(Embedder):
    """Wraps a user-supplied callable so it fits the Embedder protocol."""

    def __init__(self, fn: Callable[[str], List[float]], dim: int = 0):
        if not callable(fn):
            raise TypeError("CustomEmbedder requires a callable `fn`.")
        self.fn = fn
        self.dim = dim

    def embed(self, text: str) -> List[float]:
        return self.fn(text)

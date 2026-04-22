"""Embedder interface. One method: embed(text) -> list[float]."""
from abc import ABC, abstractmethod
from typing import List


class Embedder(ABC):
    """Turns a query string into a vector matching the stored embedding dim."""

    dim: int = 0

    @abstractmethod
    def embed(self, text: str) -> List[float]:
        """Return a single vector for the given text."""

    async def aembed(self, text: str) -> List[float]:
        """Async variant. Default: run sync embed in a thread."""
        import asyncio
        return await asyncio.to_thread(self.embed, text)

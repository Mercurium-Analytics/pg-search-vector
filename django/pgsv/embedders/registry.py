"""Embedder registry + factory. Reads settings.PGSV to build the default."""
from functools import lru_cache
from importlib import import_module
from typing import Optional

from .base import Embedder


_ALIASES = {
    "ollama":      ("pgsv.embedders.ollama",       "OllamaEmbedder"),
    "openai":      ("pgsv.embedders.openai",       "OpenAIEmbedder"),
    "mercuriumai": ("pgsv.embedders.mercuriumai",  "MercuriumAIEmbedder"),
    "custom":      ("pgsv.embedders.custom",       "CustomEmbedder"),
}


def _build(provider: str, **kwargs) -> Embedder:
    if provider in _ALIASES:
        mod, cls = _ALIASES[provider]
    elif "." in provider:
        mod, _, cls = provider.rpartition(".")
    else:
        raise ValueError(
            f"Unknown embedding provider '{provider}'. "
            f"Expected one of {list(_ALIASES)} or a dotted path."
        )
    module = import_module(mod)
    return getattr(module, cls)(**kwargs)


@lru_cache(maxsize=1)
def _default_embedder() -> Optional[Embedder]:
    from .. import conf
    cfg = conf.get_settings()
    provider = cfg.get("EMBEDDING_PROVIDER")
    if not provider:
        return None
    kwargs = dict(cfg.get("EMBEDDING_KWARGS") or {})
    if "model" not in kwargs and cfg.get("EMBEDDING_MODEL"):
        kwargs["model"] = cfg["EMBEDDING_MODEL"]
    if "dim" not in kwargs and cfg.get("EMBEDDING_DIM"):
        kwargs["dim"] = cfg["EMBEDDING_DIM"]
    return _build(provider, **kwargs)


def get_embedder(provider: Optional[str] = None, **kwargs) -> Embedder:
    """Return an embedder. No args → the one configured in settings."""
    if provider is None and not kwargs:
        emb = _default_embedder()
        if emb is None:
            raise RuntimeError(
                "No embedder configured. Set PGSV['EMBEDDING_PROVIDER'] in settings."
            )
        return emb
    return _build(provider, **kwargs)


def reset_cache() -> None:
    _default_embedder.cache_clear()

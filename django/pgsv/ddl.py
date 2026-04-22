"""DDL helpers for pg-search-vector.

The Postgres `WITH (...)` reloption parser does NOT evaluate function calls —
it captures the source token literally. That means

    CREATE INDEX ... WITH (text_fields=pgsv.bm25_preset('autocomplete'))

sends the literal token to ParadeDB, which rejects it as non-JSON. The SQL
has to be composed client-side, with the JSON baked in as a literal.

Use `bm25_index_sql(...)` inside Django migrations::

    from pgsv import bm25_index_sql
    migrations.RunSQL(
        bm25_index_sql('items_bm25', 'items', 'id', 'name', 'autocomplete'),
        reverse_sql='DROP INDEX IF EXISTS items_bm25;',
    )
"""
import json
from typing import Mapping


# Keep in lockstep with pgsv.bm25_preset in sql/pgsv.sql.
_TOKENIZERS: Mapping[str, dict] = {
    "autocomplete": {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": True},
    "substring":    {"type": "ngram", "min_gram": 2, "max_gram": 5, "prefix_only": False},
    "natural":      {"type": "default"},
    "code":         {"type": "source_code"},
}


def bm25_index_sql(
    index_name: str,
    table: str,
    key_field: str,
    text_field: str,
    preset: str = "natural",
) -> str:
    """Return a CREATE INDEX DDL string with the preset JSON baked in.

    The returned SQL has all identifiers double-quoted and the JSON payload
    single-quoted; safe to pass to ``migrations.RunSQL`` verbatim.
    """
    if preset not in _TOKENIZERS:
        raise ValueError(
            f"unknown preset {preset!r}; valid: {sorted(_TOKENIZERS)}"
        )
    text_fields_obj = {text_field: {"tokenizer": _TOKENIZERS[preset], "fast": True}}
    text_fields_literal = json.dumps(text_fields_obj).replace("'", "''")
    return (
        f'CREATE INDEX "{index_name}" '
        f'ON "{table}" USING bm25 ("{key_field}", "{text_field}") '
        f"WITH (key_field='{key_field}', text_fields='{text_fields_literal}');"
    )

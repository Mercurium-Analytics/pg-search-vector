# pg-search-vector-django

Django adapter for [pg-search-vector](https://github.com/Mercurium-Analytics/pg-search-vector).

## Install

```bash
pip install pg-search-vector-django
# or with uv
uv pip install pg-search-vector-django
```

Optional extras:

```bash
pip install 'pg-search-vector-django[pgvector,openai]'
```

Prerequisites: running Postgres with `pg_search` and `vector` extensions installed. Use the `pg-search-vector` Docker image for zero config.

## Development

```bash
# Clone + install with dev deps (uv — recommended)
git clone https://github.com/Mercurium-Analytics/pg-search-vector.git
cd pg-search-vector/django
uv venv && source .venv/bin/activate
uv pip install -e '.[dev,all]'
pytest

# Or with plain pip
python -m venv .venv && source .venv/bin/activate
pip install -e '.[dev,all]'
pytest
```

## Usage

### Lookup — easiest, works like `icontains`

```python
MyModel.objects.filter(name__bm25='robert')
```

Emits `WHERE name @@@ 'robert'`. Uses the BM25 index if one exists on the column.

### Score annotation

```python
from pgsv import BM25

qs = (
    MyModel.objects
    .filter(name__bm25='robert')
    .annotate(score=BM25())
    .order_by('-score')[:10]
)
```

`BM25()` emits `paradedb.score(<pk>)` and must be paired with a `__bm25`
filter so the planner uses the BM25 index scan.

### Hybrid search (lexical + semantic)

Use the helper — it returns scored ids in one round trip:

```python
from pgsv import hybrid_search

hits = hybrid_search(
    MyModel, 'robert',
    text_field='name', vector_field='embedding',
    k=10,
)
# hits: [HybridHit(id, lex_rank, sem_rank, rrf_score), ...]
rows = MyModel.objects.in_bulk([h.id for h in hits])
```

If `PGSV["EMBEDDING_PROVIDER"]` is configured, the query is auto-embedded;
otherwise pass `query_vec=[...]` explicitly (or `query_vec=[]` for
lexical-only).

## Index DDL

Postgres's `WITH(...)` reloption parser doesn't evaluate function calls — you
can't write `text_fields=pgsv.bm25_preset(...)` inline. Use `bm25_index_sql`
to build a DDL string with the preset JSON already baked in as a literal:

```python
from django.db import migrations
from pgsv import bm25_index_sql

class Migration(migrations.Migration):
    operations = [
        migrations.RunSQL(
            bm25_index_sql(
                index_name='mymodel_name_bm25',
                table='myapp_mymodel',
                key_field='id',
                text_field='name',
                preset='autocomplete',
            ),
            reverse_sql="DROP INDEX IF EXISTS mymodel_name_bm25;",
        ),
    ]
```

## License

MIT.

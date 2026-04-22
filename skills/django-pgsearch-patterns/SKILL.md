---
name: django-pgsearch-patterns
description: |
  **Trigger when user asks to:** use pg_search in Django, replace Elasticsearch in Django, implement Django full-text search with BM25, add hybrid search to Django ORM, or build RAG with Django and pgvector.
  **Keywords:** Django, django-paradedb, BM25 Django, Django full-text search, pgvector Django, Django HybridSearch, Django ORM vector search, Django async search.
license: MIT
compatibility: Django 4.2+, Python 3.10+, PostgreSQL 15+ with pg_search and pgvector.
metadata:
  author: pg-search-vector
---

# Django + pg_search + pgvector patterns

Django can use the pg_search + pgvector stack through two small adapter packages:
- **`django-paradedb`** for the BM25 `@@@` operator and `paradedb.score()`
- **`pgvector.django`** for the `vector` field and distance operators

Plus the `pgsv.hybrid_search()` function for one-query hybrid retrieval, called via `connection.cursor()`.

## Golden Path

### 1. Install + settings

```bash
pip install django-paradedb pgvector
```

```python
# settings.py
INSTALLED_APPS = [
    ...,
    "pgvector.django",
    "django_paradedb",
]
```

### 2. Model

```python
from django.db import models
from pgvector.django import VectorField, HnswIndex

class DocumentPage(models.Model):
    id          = models.BigAutoField(primary_key=True)
    document_id = models.BigIntegerField(db_index=True)
    text        = models.TextField()
    embedding   = VectorField(dimensions=768, null=True)
    created_at  = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            HnswIndex(
                name="doc_pages_embedding_idx",
                fields=["embedding"],
                m=16,
                ef_construction=64,
                opclasses=["vector_cosine_ops"],
            ),
        ]
```

### 3. BM25 index via migration

Django doesn't understand `USING bm25`, so use `RunSQL`:

```python
# migrations/0002_bm25_index.py
from django.db import migrations

class Migration(migrations.Migration):
    dependencies = [("yourapp", "0001_initial")]
    operations = [
        migrations.RunSQL(
            sql="""
                CREATE INDEX doc_pages_bm25
                  ON yourapp_documentpage
                  USING bm25 (id, text)
                  WITH (key_field='id');
            """,
            reverse_sql="DROP INDEX IF EXISTS doc_pages_bm25;",
        ),
    ]
```

### 4. Query via lookup

```python
from django_paradedb.fields import BM25Lookup

# Enables: TextField.bm25 lookup
models.TextField.register_lookup(BM25Lookup)

# Query
matches = DocumentPage.objects.filter(text__bm25="robert smith")
```

## Core Rules

### One model, multiple indexes
Always keep the bm25 index AND the vector index on the same table, with the same primary key. Crossing tables for hybrid is painful.

### Migrations for extension indexes always use RunSQL
bm25, hnsw, diskann — none are Django built-ins. Use `migrations.RunSQL(sql=..., reverse_sql=...)`. The pattern is copy-paste across projects.

### Don't use `icontains` on large text fields
Django devs reach for `name__icontains='robert'` habitually. On tables with >100k rows, this becomes a sequential scan (no index). Switch to `name__bm25='robert'` and add the bm25 index.

```python
# BAD at scale
DocumentPage.objects.filter(text__icontains="robert")

# GOOD
DocumentPage.objects.filter(text__bm25="robert")
```

## Standard Patterns

### BM25 + ranking annotation

```python
from django.db.models import F
from django_paradedb.expressions import BM25Score

qs = (
    DocumentPage.objects
    .filter(text__bm25="robert smith")
    .annotate(score=BM25Score("id"))      # emits: paradedb.score(id)
    .order_by("-score")[:10]
)

for doc in qs:
    print(doc.id, doc.score, doc.text[:80])
```

`BM25Score` is a Django `Expression` that emits `paradedb.score("id")` in the SQL.

### Phrase + fuzzy

```python
from django_paradedb.expressions import BM25Phrase, BM25Fuzzy

# Exact phrase
DocumentPage.objects.filter(
    text__bm25=BM25Phrase("robert smith")
).annotate(score=BM25Score("id")).order_by("-score")

# Typo-tolerant
DocumentPage.objects.filter(
    text__bm25=BM25Fuzzy("robrt", distance=1)
).annotate(score=BM25Score("id")).order_by("-score")
```

### Vector search

```python
from pgvector.django import CosineDistance

embedding = embed_query("robert smith")  # your embedding pipeline

qs = (
    DocumentPage.objects
    .annotate(distance=CosineDistance("embedding", embedding))
    .order_by("distance")[:10]
)
```

### Hybrid — raw SQL via `connection.cursor`

Django ORM doesn't compose pg_search and pgvector in one query natively. Drop to raw SQL:

```python
from django.db import connection

def hybrid_search(query_text: str, query_vec: list[float], k: int = 10):
    with connection.cursor() as cur:
        cur.execute(
            """
            SELECT h.id, h.rrf_score, d.text, d.document_id
            FROM pgsv.hybrid_search(
              'yourapp_documentpage', 'id', 'text', 'embedding',
              %s, %s::vector, %s
            ) h
            JOIN yourapp_documentpage d USING (id)
            """,
            [query_text, query_vec, k],
        )
        columns = [c.name for c in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]
```

Wrap in a manager method for reuse:

```python
class DocumentPageManager(models.Manager):
    def hybrid(self, query: str, vec: list[float], k: int = 10):
        return hybrid_search(query, vec, k)

class DocumentPage(models.Model):
    objects = DocumentPageManager()
    ...

# Usage
results = DocumentPage.objects.hybrid("robert", embedding, k=10)
```

### DRF / API integration

```python
from rest_framework.views import APIView
from rest_framework.response import Response

class HybridSearchView(APIView):
    def get(self, request):
        q = request.query_params.get("q", "").strip()
        if len(q) < 2:
            return Response([])

        vec = embed_query(q)
        results = DocumentPage.objects.hybrid(q, vec, k=10)
        return Response(results)
```

### Admin search

```python
from django.contrib import admin

@admin.register(DocumentPage)
class DocumentPageAdmin(admin.ModelAdmin):
    search_fields = ["text"]    # default uses icontains

    def get_search_results(self, request, queryset, search_term):
        # Override to use bm25 for admin search
        if search_term:
            queryset = queryset.filter(text__bm25=search_term)
        return queryset, False
```

## Embedding pipeline

### Sync embed on save (simple, not recommended at scale)

```python
from django.db.models.signals import post_save
from django.dispatch import receiver

@receiver(post_save, sender=DocumentPage)
def embed_on_save(sender, instance, created, **kwargs):
    if created and instance.embedding is None:
        instance.embedding = embed_query(instance.text)
        instance.save(update_fields=["embedding"])
```

**Problem**: synchronous OpenAI call inside a DB transaction is dangerous. Use Celery.

### Celery-based embedding (recommended)

```python
# tasks.py
from celery import shared_task

@shared_task
def embed_document_page(page_id: int):
    from yourapp.models import DocumentPage
    page = DocumentPage.objects.get(id=page_id)
    page.embedding = embed_query(page.text)
    page.save(update_fields=["embedding"])

# signals.py
@receiver(post_save, sender=DocumentPage)
def queue_embedding(sender, instance, created, **kwargs):
    if created and instance.embedding is None:
        embed_document_page.delay(instance.id)
```

### Backfill command

```python
# management/commands/backfill_embeddings.py
from django.core.management.base import BaseCommand
from yourapp.models import DocumentPage
from yourapp.tasks import embed_document_page

class Command(BaseCommand):
    def handle(self, *args, **opts):
        qs = DocumentPage.objects.filter(embedding__isnull=True)
        self.stdout.write(f"Queueing {qs.count()} embedding jobs")
        for page_id in qs.values_list("id", flat=True).iterator():
            embed_document_page.delay(page_id)
```

## Gotchas

### Django 5 async ORM is partial
Async-compatible ORM methods are limited. For RAG pipelines where async matters, prefer FastAPI + SQLAlchemy (see `fastapi-pgsearch-patterns` skill). Django stays good for sync SaaS backends.

### `connection.cursor()` inside `async` code
Django ORM inside `async def` must use `sync_to_async`. Raw cursor calls don't help — wrap them:

```python
from asgiref.sync import sync_to_async

results = await sync_to_async(hybrid_search)(query, vec, k)
```

### PREPARED statements + PgBouncer transaction mode
Django by default uses server-side prepared statements. Combined with PgBouncer `pool_mode=transaction`, this breaks on cross-transaction prepared name reuse.

Fix: disable prepared statements for the bouncer-connected DB:

```python
DATABASES = {
    "default": {
        ...,
        "DISABLE_SERVER_SIDE_CURSORS": True,
        "OPTIONS": {
            "options": "-c default_transaction_isolation=read_committed",
        },
    },
}
```

See `pgbouncer-pool-modes` skill for the full list of Django + PgBouncer traps.

### Migrations with long-running CREATE INDEX
bm25/hnsw/diskann index creation can take hours on large tables. A blocking `RunSQL` in a migration blocks deploys. Use `atomic = False` + `CREATE INDEX CONCURRENTLY`:

```python
class Migration(migrations.Migration):
    atomic = False    # required for CREATE INDEX CONCURRENTLY
    operations = [
        migrations.RunSQL(
            "CREATE INDEX CONCURRENTLY ... USING bm25 (...) ...",
            reverse_sql="DROP INDEX IF EXISTS ...;",
        ),
    ]
```

### Django test DB doesn't keep extensions
Tests create a fresh DB with only core extensions. Add:

```python
# conftest.py
@pytest.fixture(autouse=True)
def enable_extensions(django_db_setup, django_db_blocker):
    with django_db_blocker.unblock():
        from django.db import connection
        with connection.cursor() as cur:
            cur.execute("CREATE EXTENSION IF NOT EXISTS pg_search")
            cur.execute("CREATE EXTENSION IF NOT EXISTS vector")
```

## Related skills

- `pg-search-bm25` — the raw-SQL fundamentals
- `hybrid-lexical-semantic` — RRF patterns
- `pgbouncer-pool-modes` — Django + PgBouncer configuration
- `fastapi-pgsearch-patterns` — when to use FastAPI instead

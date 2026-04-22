---
name: fastapi-pgsearch-patterns
description: |
  **Trigger when user asks to:** build RAG with FastAPI, use pg_search async, add hybrid search to FastAPI, use SQLAlchemy async with pgvector, or build an AI-first API on Postgres.
  **Keywords:** FastAPI, SQLAlchemy async, asyncpg, pgvector FastAPI, pg_search FastAPI, streaming RAG, async hybrid search, Pydantic vector, RAG API.
license: MIT
compatibility: FastAPI 0.100+, SQLAlchemy 2.0+ (async), Python 3.10+, PostgreSQL 15+ with pg_search + pgvector.
metadata:
  author: pg-search-vector
---

# FastAPI + pg_search + pgvector patterns

FastAPI is the natural fit for RAG / AI / hybrid-search APIs: async end-to-end, typed with Pydantic, streams well. pg_search + pgvector sit behind it as the unified retrieval layer.

## Golden Path

### 1. Dependencies

```toml
# pyproject.toml
[project]
dependencies = [
  "fastapi",
  "sqlalchemy[asyncio]>=2.0",
  "asyncpg",
  "pgvector",           # includes pgvector's SQLAlchemy integration
  "pydantic>=2",
]
```

### 2. Database setup

```python
# db.py
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase

DATABASE_URL = "postgresql+asyncpg://app:pw@db:6432/app"  # PgBouncer port

engine = create_async_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

async def get_session() -> AsyncSession:
    async with SessionLocal() as session:
        yield session
```

### 3. Model

```python
# models.py
from sqlalchemy import BigInteger, Text
from sqlalchemy.orm import Mapped, mapped_column
from pgvector.sqlalchemy import Vector

class DocumentPage(Base):
    __tablename__ = "document_pages"

    id:          Mapped[int]          = mapped_column(BigInteger, primary_key=True)
    document_id: Mapped[int]          = mapped_column(BigInteger, index=True)
    text:        Mapped[str]          = mapped_column(Text)
    embedding:   Mapped[list[float]]  = mapped_column(Vector(768), nullable=True)
```

### 4. Indexes (via Alembic or raw SQL on bootstrap)

```python
# alembic/versions/xxxx_bm25_and_vector.py
from alembic import op

def upgrade():
    op.execute("""
        CREATE INDEX doc_pages_bm25 ON document_pages
          USING bm25 (id, text) WITH (key_field='id');
    """)
    op.execute("""
        CREATE INDEX doc_pages_vec ON document_pages
          USING hnsw (embedding vector_cosine_ops);
    """)

def downgrade():
    op.execute("DROP INDEX IF EXISTS doc_pages_bm25")
    op.execute("DROP INDEX IF EXISTS doc_pages_vec")
```

### 5. Query helpers

```python
# search.py
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

async def bm25_search(session: AsyncSession, q: str, k: int = 10) -> list[dict]:
    rows = (await session.execute(text("""
        SELECT id, text, paradedb.score(id) AS score
        FROM document_pages
        WHERE text @@@ :q
        ORDER BY score DESC
        LIMIT :k
    """), {"q": q, "k": k})).mappings().all()
    return [dict(r) for r in rows]

async def vector_search(session: AsyncSession, vec: list[float], k: int = 10) -> list[dict]:
    rows = (await session.execute(text("""
        SELECT id, text, embedding <=> CAST(:vec AS vector) AS distance
        FROM document_pages
        ORDER BY distance
        LIMIT :k
    """), {"vec": vec, "k": k})).mappings().all()
    return [dict(r) for r in rows]

async def hybrid_search(
    session: AsyncSession, q: str, vec: list[float], k: int = 10,
) -> list[dict]:
    rows = (await session.execute(text("""
        SELECT h.id, h.rrf_score, h.lex_rank, h.sem_rank, d.text
        FROM pgsv.hybrid_search(
          'document_pages', 'id', 'text', 'embedding',
          :q, CAST(:vec AS vector), :k
        ) h
        JOIN document_pages d USING (id)
    """), {"q": q, "vec": vec, "k": k})).mappings().all()
    return [dict(r) for r in rows]
```

### 6. Routes

```python
# main.py
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from .db import get_session
from .search import hybrid_search
from .embed import embed_query   # your embedding function

app = FastAPI()

class SearchHit(BaseModel):
    id: int
    text: str
    rrf_score: float
    lex_rank: int | None
    sem_rank: int | None

@app.get("/search", response_model=list[SearchHit])
async def search(q: str, k: int = 10, session=Depends(get_session)):
    if len(q.strip()) < 2:
        return []
    vec = await embed_query(q)
    return await hybrid_search(session, q, vec, k)
```

Three files, end-to-end hybrid RAG search.

## Core Rules

### Use asyncpg, not psycopg
SQLAlchemy async on asyncpg is 2-3× faster than on psycopg-async for read-heavy workloads. `postgresql+asyncpg://` is the DSN.

### Connect to PgBouncer (6432) for app traffic
Your Django / FastAPI app connects on port 6432 (PgBouncer). Migrations and admin tools connect on 5432 (direct Postgres).

```python
# .env
DATABASE_URL=postgresql+asyncpg://app:pw@db:6432/app       # <-- 6432 for app
DATABASE_URL_ADMIN=postgresql+asyncpg://postgres:pw@db:5432/app  # 5432 for migrations
```

### Type queries with Pydantic response models
```python
class HybridHit(BaseModel):
    id: int
    text: str
    rrf_score: float
    lex_rank: int | None = None
    sem_rank: int | None = None
```
FastAPI generates OpenAPI docs with these automatically. Clients get typed responses.

### Stream responses for RAG
When users ask LLMs questions, stream tokens back as they arrive. Don't wait for the full answer:

```python
from fastapi.responses import StreamingResponse

@app.get("/chat")
async def chat(q: str, session=Depends(get_session)):
    vec = await embed_query(q)
    hits = await hybrid_search(session, q, vec, k=5)
    context = "\n\n".join(h["text"] for h in hits)
    prompt = f"Context:\n{context}\n\nQuestion: {q}\nAnswer:"

    async def stream():
        async for token in openai_stream(prompt):
            yield token

    return StreamingResponse(stream(), media_type="text/plain")
```

## Standard Patterns

### Embedding helper with Redis cache

```python
# embed.py
import hashlib
import json
import redis.asyncio as redis
from openai import AsyncOpenAI

r = redis.Redis(host="redis", decode_responses=True)
oai = AsyncOpenAI()
MODEL = "text-embedding-3-small"

async def embed_query(q: str) -> list[float]:
    key = f"emb:{MODEL}:{hashlib.sha1(q.encode()).hexdigest()}"
    cached = await r.get(key)
    if cached:
        return json.loads(cached)
    resp = await oai.embeddings.create(model=MODEL, input=q)
    vec = resp.data[0].embedding
    await r.set(key, json.dumps(vec), ex=86400)
    return vec
```

### Bulk embedding with concurrency

```python
import asyncio
from sqlalchemy import select, update

BATCH = 100
CONCURRENCY = 10

async def backfill(session: AsyncSession):
    unembedded = (await session.execute(
        select(DocumentPage).where(DocumentPage.embedding.is_(None)).limit(1000)
    )).scalars().all()

    sem = asyncio.Semaphore(CONCURRENCY)
    async def embed_one(page):
        async with sem:
            page.embedding = await embed_query(page.text)

    await asyncio.gather(*(embed_one(p) for p in unembedded))
    await session.commit()
```

### Pre-filtered hybrid (multi-tenant)

```python
async def hybrid_search_tenant(
    session: AsyncSession, tenant_id: int, q: str, vec: list[float], k: int = 10
):
    rows = (await session.execute(text("""
        WITH
          lex AS (
            SELECT id, ROW_NUMBER() OVER (ORDER BY paradedb.score(id) DESC) AS r
            FROM document_pages
            WHERE tenant_id = :tenant_id AND text @@@ :q
            LIMIT 100
          ),
          sem AS (
            SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> CAST(:vec AS vector)) AS r
            FROM document_pages
            WHERE tenant_id = :tenant_id
            ORDER BY embedding <=> CAST(:vec AS vector)
            LIMIT 100
          )
        SELECT COALESCE(lex.id, sem.id) AS id,
               COALESCE(1.0::float/(60 + lex.r), 0)
             + COALESCE(1.0::float/(60 + sem.r), 0) AS rrf
        FROM lex FULL OUTER JOIN sem USING (id)
        ORDER BY rrf DESC LIMIT :k
    """), {"tenant_id": tenant_id, "q": q, "vec": vec, "k": k})).mappings().all()
    return [dict(r) for r in rows]
```

### Background ingest via arq / Celery-py / Taskiq

```python
# tasks.py
from taskiq import TaskiqScheduler, AsyncBroker
from taskiq_redis import ListQueueBroker

broker = ListQueueBroker("redis://redis:6379")

@broker.task
async def ingest_document(document_id: int):
    # Fetch, chunk, embed, insert
    ...
```

## Gotchas

### Do NOT use `session.execute` inside response streaming
Once you start streaming the response, the DB session's transaction may end. Compute all DB reads BEFORE yielding:

```python
async def stream():
    hits = await hybrid_search(session, q, vec)  # done within session
    async for token in llm_stream(build_prompt(q, hits)):
        yield token   # session may be gone, but we don't need it anymore
```

### asyncpg prepared-statement cache + PgBouncer transaction mode
asyncpg caches prepared statements client-side. PgBouncer in transaction mode rotates server connections — the prepared statement isn't on the new backend. Disable caching:

```python
engine = create_async_engine(
    DATABASE_URL,
    connect_args={"statement_cache_size": 0, "prepared_statement_cache_size": 0},
)
```

See `pgbouncer-pool-modes` skill for detail.

### Vector dimensions must match column definition
```python
class DocumentPage(Base):
    embedding = mapped_column(Vector(768), ...)  # fixed 768

# Inserting a 1024-dim vector raises an error at INSERT time.
```

Pin the dimension to your embedding model at table creation. If you change models, migrate to a new column.

### Don't SELECT embedding if you don't need it
Returning `vector(768)` in HTTP responses bloats payloads by 3-6 KB per row. Select only what the client needs:

```python
# BAD
rows = (await session.execute(select(DocumentPage))).scalars().all()

# GOOD
rows = (await session.execute(
    select(DocumentPage.id, DocumentPage.text).where(...)
)).all()
```

### Connection leaks in long-lived background tasks
Workers running 24/7 must close sessions explicitly or use async context managers. Otherwise `pool_size` silently exhausts.

```python
# BAD
async def worker():
    session = SessionLocal()
    while True:
        await session.execute(...)  # leaks on exception

# GOOD
async def worker():
    while True:
        async with SessionLocal() as session:
            await session.execute(...)
```

## Related skills

- `hybrid-lexical-semantic` — the retrieval algorithm
- `pgvectorscale-diskann` — swap HNSW for DiskANN at scale
- `pgbouncer-pool-modes` — asyncpg + PgBouncer config
- `pg-cron-scheduling` — cron jobs for embedding backfills

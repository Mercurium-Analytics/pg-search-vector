# pg-search-vector skills

Opinionated skills for AI coding agents working with the **pg_search + pgvector + pgvectorscale** stack on Postgres 17.

Pairs with [`timescale/pg-aiguide`](https://github.com/timescale/pg-aiguide) (general Postgres advice) — install both for complete coverage.

## What's in here

| Skill | Purpose |
|---|---|
| `pg-search-bm25` | BM25 full-text search via ParadeDB pg_search |
| `pgvectorscale-diskann` | DiskANN + SBQ for >10M vector tables |
| `hybrid-lexical-semantic` | RRF fusion of BM25 + vector similarity |
| `django-pgsearch-patterns` | Django ORM integration (django-paradedb) |
| `fastapi-pgsearch-patterns` | FastAPI + async SQLAlchemy patterns |
| `pg-repack-runbook` | Online table reorg, no downtime |
| `pg-partman-partitioning` | Automated partition management at scale |
| `pg-cron-scheduling` | In-DB job scheduler |
| `pgbouncer-pool-modes` | Pool-mode traps for Django / FastAPI |
| `bm25-tokenizer-guide` | Which tokenizer for which workload |

## Install

```bash
npx skills add Mercurium-Analytics/pg-search-vector
```

Or pick individual skills:

```bash
npx skills add Mercurium-Analytics/pg-search-vector --skill pg-search-bm25
npx skills add Mercurium-Analytics/pg-search-vector --skill hybrid-lexical-semantic
```

Works with Claude Code, Cursor, Codex, Gemini CLI, Windsurf, Goose, and 40+ other agents via Vercel Labs' [`skills`](https://github.com/vercel-labs/skills) CLI.

## Format

Each skill is a single `SKILL.md` with YAML frontmatter (trigger keywords + compatibility), a **Golden Path** section (the recommended default), **Core Rules**, **Standard Patterns** (ready-to-paste code), and **Gotchas**. Structure mirrors pg-aiguide so agents that use both see consistent organization.

## License

MIT (see `LICENSE`). Individual skills may reference or link to upstream documentation from Apache-2.0 and PostgreSQL-licensed projects (pg_search, pgvector, pgvectorscale, pg_partman, pg_cron, etc.) — those references are covered by the respective upstream licenses.

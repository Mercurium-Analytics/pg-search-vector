# Publishing pg-search-vector

End-to-end checklist for shipping `pg-search-vector` as an open-source image +
deploying to Railway. All steps require **your approval and credentials** —
nothing here is run automatically.

## 1. Open-source repo (GitHub, MIT)

### What's already in the tree

- `LICENSE` (MIT)
- `README.md`
- `PERFORMANCE.md` — measured benchmarks
- `ILIKE_AUDIT.md` — DoS surface audit
- `Dockerfile`, `Dockerfile.pooled`
- `sql/pgsv.sql` — BM25 / vector / hybrid helpers
- `init/*.sh` — first-boot scripts (tuning, app role, WAL-G)
- `pooled/*.sh` — PgBouncer supervisor
- `backup/`, `bin/`, `conf.d/`
- `deploy/railway.json` `deploy/fly.toml` `deploy/render.yaml` `deploy/kubernetes/`
- `skills/` — 10 agent skill files (publishable via `npx skills add`)
- `django/` — companion Python package (`pg-search-vector-django`)
- `.github/workflows/build-and-publish.yml` — multi-arch GHCR publish

### Decisions you need to make before publishing

| Decision | Options | Recommendation |
|---|---|---|
| Repo location | new `pg-search-vector` repo under a GitHub org, or a subfolder of `mercurium-analytics` | **New standalone repo** — easier to discover, package independently |
| Repo org | `mercuriumanalytics` (personal) or a new `paradedb-extras` | `mercuriumanalytics` is simplest |
| First tag | `v0.1.0` or `v0.4.0` (matches internal) | **`v0.4.0`** to match current internal versioning |
| License header in each file | yes / no | **No** — `LICENSE` at root is enough |

### Publish steps — after you decide the repo name

1. Create the empty GitHub repo (do NOT run `gh` from here; do it yourself).
2. From the Mercurium workspace:
   ```bash
   cp -R pg-search-vector/ /tmp/pg-search-vector-release/
   cd /tmp/pg-search-vector-release/
   git init && git add -A && git commit -m "Initial release v0.4.0"
   git remote add origin git@github.com:Mercurium-Analytics/pg-search-vector.git
   git branch -M main && git push -u origin main
   git tag v0.4.0 && git push origin v0.4.0
   ```
3. Pushing the tag fires `.github/workflows/build-and-publish.yml` which
   builds both `Dockerfile` + `Dockerfile.pooled` for `linux/amd64` and
   `linux/arm64`, then pushes to `ghcr.io/mercurium-analytics/pg-search-vector`.
4. Verify:
   ```bash
   docker pull ghcr.io/mercurium-analytics/pg-search-vector:v0.4.0-pg17
   docker pull ghcr.io/mercurium-analytics/pg-search-vector:v0.4.0-pg17-pooled
   ```

## 2. Docker Hub mirror (optional)

GHCR is fine for most users; Docker Hub just improves discoverability.

Add a parallel job to the workflow after confirming it works on GHCR:

```yaml
# .github/workflows/build-and-publish.yml — append a step
- name: Log in to Docker Hub
  uses: docker/login-action@v3
  with:
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}

- name: Push Docker Hub
  uses: docker/build-push-action@v6
  with:
    context: pg-search-vector
    file: pg-search-vector/${{ matrix.variant.dockerfile }}
    platforms: linux/amd64,linux/arm64
    push: true
    tags: |
      YOUR_DOCKERHUB_USER/pg-search-vector:v0.4.0-${{ matrix.variant.suffix }}
      YOUR_DOCKERHUB_USER/pg-search-vector:${{ matrix.variant.suffix }}
```

Secrets needed: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (access token with
Read/Write scope, created at hub.docker.com → Security).

## 3. Railway deploy

`deploy/railway.json` already points at `Dockerfile.pooled`. Two approaches:

### Approach A — deploy from GitHub repo (recommended)

1. Railway dashboard → New Project → Deploy from GitHub repo.
2. Select `Mercurium-Analytics/pg-search-vector`.
3. Railway picks up `railway.json` and builds `Dockerfile.pooled`.
4. Environment variables to set:
   ```
   POSTGRES_PASSWORD=<strong>
   POSTGRES_USER=postgres
   POSTGRES_DB=mercurium
   POSTGRES_APP_USER=app
   POSTGRES_APP_PASSWORD=<strong>
   PGBOUNCER_POOL_MODE=transaction
   PGBOUNCER_DEFAULT_POOL_SIZE=20
   PGBOUNCER_MAX_CLIENT_CONN=500
   PGSV_SHARED_BUFFERS=2GB          # Railway Pro = 8GB RAM
   PGSV_WORK_MEM=32MB
   PGSV_EFFECTIVE_CACHE_SIZE=6GB
   PGSV_MAINTENANCE_WORK_MEM=1GB
   PGSV_MAX_PARALLEL_WORKERS_PER_GATHER=2
   ```
5. Mount a volume at `/var/lib/postgresql/data` — Railway Volumes tab.
6. Expose ports **5432** (direct, for `pg_dump` / admin) and **6432**
   (PgBouncer, for app traffic). Railway assigns a public URL per port.
7. Point Django at the PgBouncer URL: `DB_PORT=6432`.

### Approach B — pre-built image from GHCR

1. Railway → Deploy from Docker Image.
2. Image: `ghcr.io/mercurium-analytics/pg-search-vector:v0.4.0-pg17-pooled`.
3. Same env vars / volume / ports as above.
4. Faster first deploy (no build), but every upgrade = new tag.

### Backup configuration (WAL-G, optional but recommended)

`init/30-walg-bootstrap.sh` enables continuous WAL archiving when these
env vars are set:

```
WALG_S3_PREFIX=s3://your-bucket/app-prod
AWS_ACCESS_KEY_ID=<cloudflare-r2-key>
AWS_SECRET_ACCESS_KEY=<cloudflare-r2-secret>
AWS_REGION=auto
AWS_ENDPOINT=https://<account>.r2.cloudflarestorage.com
```

Point at Cloudflare R2 (S3-compatible, cheap, no egress). See
`bin/wal-g-archive.sh`, `bin/wal-g-basebackup.sh`, `bin/wal-g-restore.sh`.

## 4. Django companion package (PyPI)

Located at `django/`. To publish:

```bash
cd pg-search-vector/django/
pip install build twine
python -m build                # creates dist/pg_search_vector_django-0.2.0-*
twine upload dist/*            # prompts for PyPI credentials
```

First-time setup: register `pg-search-vector-django` on PyPI (or test on
test.pypi.org first). Repo and project-urls should point at the GitHub
repo.

## 5. Skills bundle (for AI coding agents)

Located at `skills/`. Published via the Vercel `skills` CLI (separate
registry from npm):

```bash
cd pg-search-vector/skills/
npx skills publish
```

Requires a `skills.yaml` in the directory (already present) and a Vercel
account.

Users then add the bundle with:
```bash
npx skills add pg-search-vector
```

## 6. Post-publish smoke test

After the first Railway deploy:

```bash
# 1. Direct connection works
PGPASSWORD=<pw> psql -h <railway-direct> -p 5432 -U postgres -d mercurium \
  -c "SELECT pgsv.version();"

# 2. Pooled connection works
PGPASSWORD=<pw> psql -h <railway-pooled> -p 6432 -U postgres -d mercurium \
  -c "SHOW POOLS;"

# 3. Ship a trivial migration through PgBouncer (verifies transaction pooling)
docker-compose run --rm django env DB_PORT=6432 python manage.py showmigrations

# 4. Run pgsv_bench against the live DB
docker-compose run --rm django python manage.py pgsv_bench \
  --model collect.BusinessRegistryRecord \
  --text-field name \
  --queries "acme,smith,microsoft,robert,holdings" \
  --runs 20 --concurrency 10
```

Compare the Railway numbers to `PERFORMANCE.md` section 4. If sustained
tps on Railway matches or beats local (likely, with faster disk), ES
cutover is go.

## 7. Rollback plan

| Failure | Rollback action |
|---|---|
| Railway deploy fails build | Redeploy previous green tag (`v0.3.0-pg17-pooled`) |
| App connects but queries hang | Swap Django `DB_PORT` 6432→5432 (bypass pooler) |
| PgBouncer stats show `maxwait` spiking | Increase `PGBOUNCER_DEFAULT_POOL_SIZE` env var + restart |
| Data corruption (WAL replay failure) | Restore from last WAL-G base backup (< 24h old) |
| Complete database failure | Keep prod ES index untouched until first green Railway week |

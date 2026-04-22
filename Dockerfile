# pg-search-vector: Postgres with pgvector + pg_search pre-installed.
#
# Base: pgvector/pgvector (Debian bookworm, Postgres 17)
# Adds: ParadeDB pg_search + pgsv helpers + tuned defaults + init scripts.
#
# Build:
#   docker build -t pg-search-vector:pg17 .
#
# Build multi-arch (Apple Silicon + Linux amd64):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/OWNER/pg-search-vector:pg17 --push .

# ── Stage 1: grab pgvectorscale from Timescale's official image ──
# NOTE: this pulls a 2 GB image. Intended for CI / cloud builds, NOT laptop
# rebuilds. For local dev on a resource-constrained machine, pull the
# pre-built image from ghcr.io instead of rebuilding.
FROM timescale/timescaledb-ha:pg17 AS vectorscale_source

# ── Stage 2: our image, based on upstream pgvector ──
FROM pgvector/pgvector:pg17-bookworm

ARG PG_SEARCH_VERSION=0.23.0
ARG PGSV_VERSION=0.2.0
ARG TARGETARCH

LABEL org.opencontainers.image.title="pg-search-vector"
LABEL org.opencontainers.image.description="Postgres 17 + pgvector + pg_search. Hybrid lexical+semantic search in one container."
LABEL org.opencontainers.image.source="https://github.com/Mercurium-Analytics/pg-search-vector"
LABEL org.opencontainers.image.version="${PGSV_VERSION}-pg17"
LABEL org.opencontainers.image.licenses="MIT"

# ── WAL-G for PITR backups (static binary from GitHub releases) ──
ARG WALG_VERSION=3.0.8
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
 && ARCH=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo amd64) \
 && wget -qO /tmp/wal-g.tar.gz \
      "https://github.com/wal-g/wal-g/releases/download/v${WALG_VERSION}/wal-g-pg-22.04-${ARCH}.tar.gz" \
 && tar -xzf /tmp/wal-g.tar.gz -C /usr/local/bin \
 && mv /usr/local/bin/wal-g-pg-22.04-${ARCH} /usr/local/bin/wal-g \
 && chmod +x /usr/local/bin/wal-g \
 && rm /tmp/wal-g.tar.gz \
 && apt-get purge -y --auto-remove wget \
 && rm -rf /var/lib/apt/lists/*

# ── pg_search + pg_repack + pg_partman + pg_cron ──
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates \
      postgresql-17-repack \
      postgresql-17-partman \
      postgresql-17-cron \
      postgresql-17-pgaudit \
      postgresql-17-pg-wait-sampling \
 && ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo amd64) \
 && curl -fsSL \
      "https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/postgresql-17-pg-search_${PG_SEARCH_VERSION}-1PARADEDB-bookworm_${ARCH}.deb" \
      -o /tmp/pg_search.deb \
 && apt-get install -y /tmp/pg_search.deb \
 && rm /tmp/pg_search.deb \
 && apt-get purge -y --auto-remove curl \
 && rm -rf /var/lib/apt/lists/*

# ── pgvectorscale: copy compiled artifacts from Timescale's image ──
COPY --from=vectorscale_source /usr/lib/postgresql/17/lib/vectorscale*.so  /usr/lib/postgresql/17/lib/
COPY --from=vectorscale_source /usr/share/postgresql/17/extension/vectorscale*.control /usr/share/postgresql/17/extension/
COPY --from=vectorscale_source /usr/share/postgresql/17/extension/vectorscale--*.sql   /usr/share/postgresql/17/extension/

# ── Build-time sanity check ──
RUN test -f /usr/lib/postgresql/17/lib/pg_search.so \
 && test -f /usr/share/postgresql/17/extension/pg_search.control \
 && test -f /usr/lib/postgresql/17/lib/vector.so \
 && test -f /usr/share/postgresql/17/extension/vector.control \
 && test -f /usr/lib/postgresql/17/lib/pg_repack.so \
 && test -f /usr/share/postgresql/17/extension/pg_repack.control \
 && test -x /usr/bin/pg_repack \
 && test -f /usr/lib/postgresql/17/lib/pg_partman_bgw.so \
 && test -f /usr/share/postgresql/17/extension/pg_partman.control \
 && test -f /usr/lib/postgresql/17/lib/pg_cron.so \
 && test -f /usr/share/postgresql/17/extension/pg_cron.control \
 && test -f /usr/lib/postgresql/17/lib/pgaudit.so \
 && test -f /usr/share/postgresql/17/extension/pgaudit.control \
 && test -f /usr/lib/postgresql/17/lib/pg_wait_sampling.so \
 && test -f /usr/share/postgresql/17/extension/pg_wait_sampling.control \
 && ls /usr/lib/postgresql/17/lib/vectorscale*.so > /dev/null \
 && ls /usr/share/postgresql/17/extension/vectorscale*.control > /dev/null \
 && echo "all extensions OK"

# ── Ship our config + helpers ──
COPY conf.d/10-tuning.conf /etc/postgresql/conf.d/10-tuning.conf
COPY sql/pgsv.sql /usr/local/share/pgsv/pgsv.sql
COPY init/00-pgsv.sh /docker-entrypoint-initdb.d/00-pgsv.sh
COPY init/10-tuning.sh /docker-entrypoint-initdb.d/10-tuning.sh
COPY init/20-app-role.sh /docker-entrypoint-initdb.d/20-app-role.sh
COPY init/30-walg-bootstrap.sh /docker-entrypoint-initdb.d/30-walg-bootstrap.sh

# WAL-G helper scripts: archive_command wrapper, base backup, restore,
# plus the shared configure + opt-in-on-running-cluster entrypoints.
COPY bin/wal-g-archive.sh        /usr/local/bin/wal-g-archive.sh
COPY bin/wal-g-basebackup.sh     /usr/local/bin/wal-g-basebackup.sh
COPY bin/wal-g-restore.sh        /usr/local/bin/wal-g-restore.sh
COPY bin/pgsv-walg-configure.sh  /usr/local/bin/pgsv-walg-configure.sh
COPY bin/pgsv-walg-enable.sh     /usr/local/bin/pgsv-walg-enable.sh

RUN chmod +x /docker-entrypoint-initdb.d/*.sh \
           /usr/local/bin/wal-g-archive.sh \
           /usr/local/bin/wal-g-basebackup.sh \
           /usr/local/bin/wal-g-restore.sh \
           /usr/local/bin/pgsv-walg-configure.sh \
           /usr/local/bin/pgsv-walg-enable.sh \
 && chown -R postgres:postgres /etc/postgresql/conf.d \
 && chmod 755 /etc/postgresql/conf.d

# Ensure postgres includes our conf.d dir
RUN echo "include_dir = '/etc/postgresql/conf.d'" \
    >> /usr/share/postgresql/postgresql.conf.sample

# ── Liveness + graceful shutdown ──
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 -q || exit 1

# SIGINT = Fast Shutdown in postgres; SIGTERM is Smart (waits for clients).
# We prefer SIGINT so `docker stop` doesn't hang when clients are connected.
STOPSIGNAL SIGINT

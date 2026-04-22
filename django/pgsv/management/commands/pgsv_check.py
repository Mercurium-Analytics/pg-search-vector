"""Validate that the target Postgres has pg-search-vector installed."""
from django.core.management.base import BaseCommand
from django.db import connection

from pgsv import conf
from pgsv.embedders import get_embedder


class Command(BaseCommand):
    help = "Check pg-search-vector readiness: extensions, pgsv schema, embedder."

    def handle(self, *args, **opts):
        ok = True

        ext_rows = self._query(
            "SELECT extname, extversion FROM pg_extension "
            "WHERE extname IN ('pg_search','vector','vectorscale') ORDER BY extname"
        )
        got = {r[0]: r[1] for r in ext_rows}
        for name in ("pg_search", "vector"):
            if name in got:
                self._ok(f"ext {name} {got[name]}")
            else:
                ok = False
                self._err(f"ext {name} MISSING")
        if "vectorscale" in got:
            self._ok(f"ext vectorscale {got['vectorscale']}")

        schema = self._query("SELECT 1 FROM pg_namespace WHERE nspname = 'pgsv'")
        if schema:
            self._ok("schema pgsv present")
        else:
            ok = False
            self._err("schema pgsv MISSING — pgsv.sql not loaded")

        fn = self._query(
            "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname='pgsv' AND p.proname='hybrid_search'"
        )
        if fn:
            self._ok("pgsv.hybrid_search() present")
        else:
            ok = False
            self._err("pgsv.hybrid_search() MISSING")

        cfg = conf.get_settings()
        provider = cfg.get("EMBEDDING_PROVIDER")
        if not provider:
            self.stdout.write("  embedder: none configured (lexical-only)")
        else:
            try:
                emb = get_embedder()
                self._ok(f"embedder {provider} loaded ({emb.__class__.__name__})")
            except Exception as e:
                ok = False
                self._err(f"embedder {provider} FAILED: {e}")

        if ok:
            self.stdout.write(self.style.SUCCESS("pgsv_check: OK"))
        else:
            self.stdout.write(self.style.ERROR("pgsv_check: FAILED"))

    def _query(self, sql):
        with connection.cursor() as cur:
            cur.execute(sql)
            return cur.fetchall()

    def _ok(self, msg):
        self.stdout.write(self.style.SUCCESS(f"  OK  {msg}"))

    def _err(self, msg):
        self.stdout.write(self.style.ERROR(f"  ERR {msg}"))

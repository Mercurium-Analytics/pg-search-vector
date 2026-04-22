"""Reproducible benchmark of pg-search-vector against any Django model.

Usage::

    python manage.py pgsv_bench \\
        --model myapp.Document \\
        --text-field content \\
        --vector-field embedding \\
        --queries "beneficial owner,governing law,net asset value" \\
        --runs 10 --concurrency 10

Reports per-query p50 / p95 / p99 and a throughput estimate.
"""
import concurrent.futures
import statistics
import time
from typing import List

from django.apps import apps
from django.core.management.base import BaseCommand, CommandError
from django.db import connections


class Command(BaseCommand):
    help = "Benchmark pg-search-vector BM25 / hybrid search on a Django model."

    def add_arguments(self, parser):
        parser.add_argument("--model", required=True,
                            help="Model label e.g. myapp.Document")
        parser.add_argument("--text-field", required=True,
                            help="Name of the indexed text field (e.g. 'name', 'page_content')")
        parser.add_argument("--vector-field", default=None,
                            help="Optional vector field for hybrid search")
        parser.add_argument("--queries", required=True,
                            help="Comma-separated query strings")
        parser.add_argument("--k", type=int, default=10,
                            help="Top-K per query")
        parser.add_argument("--runs", type=int, default=10,
                            help="Runs per query (for p50/p95/p99)")
        parser.add_argument("--concurrency", type=int, default=1,
                            help="Parallel clients for throughput estimate")
        parser.add_argument("--mode", default="bm25",
                            choices=("bm25", "hybrid"),
                            help="bm25 (lexical-only) or hybrid (requires --vector-field)")
        parser.add_argument("--database", default="default",
                            help="Which DATABASES entry to hit")

    def handle(self, *args, **opts):
        model_label = opts["model"]
        try:
            Model = apps.get_model(model_label)
        except (LookupError, ValueError) as e:
            raise CommandError(f"Bad --model {model_label!r}: {e}")

        text_field = opts["text_field"]
        vector_field = opts["vector_field"]
        queries = [q.strip() for q in opts["queries"].split(",") if q.strip()]
        k = opts["k"]
        runs = opts["runs"]
        concurrency = opts["concurrency"]
        mode = opts["mode"]
        db = opts["database"]

        if mode == "hybrid" and not vector_field:
            raise CommandError("--mode hybrid requires --vector-field")

        table = Model._meta.db_table
        pk = Model._meta.pk.column

        self.stdout.write(self.style.SUCCESS(
            f"\n▸ pgsv_bench: {model_label} ({table}) "
            f"{mode} k={k} runs={runs} concurrency={concurrency}\n"
        ))

        if mode == "hybrid":
            from pgsv import hybrid_search
            def runner(q):
                t0 = time.perf_counter_ns()
                hybrid_search(Model, q,
                              text_field=text_field,
                              vector_field=vector_field, k=k)
                return (time.perf_counter_ns() - t0) / 1_000_000
        else:
            def runner(q):
                t0 = time.perf_counter_ns()
                with connections[db].cursor() as cur:
                    cur.execute(
                        f'SELECT {pk} FROM "{table}" '
                        f'WHERE "{text_field}" @@@ %s '
                        f'ORDER BY paradedb.score({pk}) DESC LIMIT %s',
                        [q, k],
                    )
                    cur.fetchall()
                return (time.perf_counter_ns() - t0) / 1_000_000

        hdr = f"{'query':<30} {'p50':>8} {'p95':>8} {'p99':>8} {'mean':>8} {'max':>8}"
        self.stdout.write(hdr)
        self.stdout.write("-" * len(hdr))

        for q in queries:
            latencies = self._measure(runner, q, runs)
            self._print_row(q, latencies)

        if concurrency > 1:
            self.stdout.write("\n▸ Concurrent throughput\n")
            for q in queries:
                total_ms, completed = self._throughput(runner, q, concurrency, runs)
                qps = int(completed * 1000 / total_ms) if total_ms else 0
                self.stdout.write(
                    f"  {q:<30} {completed} req in {total_ms:.0f}ms "
                    f"→ {qps} qps ({concurrency} clients)"
                )

    def _measure(self, runner, q, runs) -> List[float]:
        # Warmup
        runner(q)
        return [runner(q) for _ in range(runs)]

    def _throughput(self, runner, q, concurrency, runs):
        t0 = time.perf_counter_ns()
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = [pool.submit(runner, q) for _ in range(runs * concurrency)]
            completed = sum(1 for f in concurrent.futures.as_completed(futures))
        return (time.perf_counter_ns() - t0) / 1_000_000, completed

    def _print_row(self, q, latencies):
        vals = sorted(latencies)
        p50 = statistics.median(vals)
        p95 = vals[min(len(vals) - 1, int(len(vals) * 0.95))]
        p99 = vals[min(len(vals) - 1, int(len(vals) * 0.99))]
        mean = statistics.mean(vals)
        mx = max(vals)
        truncated = q[:28] + ".." if len(q) > 30 else q
        self.stdout.write(
            f"{truncated:<30} {p50:>7.1f}ms {p95:>7.1f}ms {p99:>7.1f}ms "
            f"{mean:>7.1f}ms {mx:>7.1f}ms"
        )

"""Expressions for BM25 scoring via Django ORM.

See `pgsv.search.hybrid_search` for the high-level hybrid (BM25 + vector)
helper — it returns (id, ranks, score) tuples in one round trip and is the
recommended path for hybrid queries.
"""
from django.db.models import Expression, FloatField


class BM25(Expression):
    """
    Annotation that returns the pg_search BM25 score for the current row.

    Must be paired with a ``<field>__bm25='query'`` filter so that the
    resulting plan uses the BM25 index scan — ``paradedb.score()`` is only
    defined for rows returned by that scan.

    Usage::

        qs = (
            MyModel.objects
            .filter(name__bm25='robert')
            .annotate(score=BM25())
            .order_by('-score')[:10]
        )

    Translates to: ``paradedb.score("<pk>")``.
    """
    output_field = FloatField()

    def as_sql(self, compiler, connection):
        model = compiler.query.model
        pk = model._meta.pk.column
        # pk is a Django-validated column name (not user input) so direct
        # interpolation into the identifier is safe.
        return f'paradedb.score("{pk}")', []

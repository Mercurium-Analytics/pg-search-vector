"""Custom lookup: field__bm25='query' → field @@@ 'query'."""
from django.db.models import CharField, TextField, Lookup


class BM25Lookup(Lookup):
    """
    Usage:
        MyModel.objects.filter(name__bm25='robert')

    Emits:
        WHERE name @@@ 'robert'
    """
    lookup_name = 'bm25'

    def as_sql(self, compiler, connection):
        lhs, lhs_params = self.process_lhs(compiler, connection)
        rhs, rhs_params = self.process_rhs(compiler, connection)
        return f"{lhs} @@@ {rhs}", list(lhs_params) + list(rhs_params)


def register_lookups():
    CharField.register_lookup(BM25Lookup)
    TextField.register_lookup(BM25Lookup)

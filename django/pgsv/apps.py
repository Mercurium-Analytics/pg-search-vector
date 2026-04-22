from django.apps import AppConfig


class PgsvConfig(AppConfig):
    name = "pgsv"
    verbose_name = "pg-search-vector"

    def ready(self):
        from .lookups import register_lookups
        register_lookups()

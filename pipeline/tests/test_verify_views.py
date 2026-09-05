from jobs import verify_views


def test_declared_relations_finds_analytics_and_ingest_table_names():
    texts = [
        'class A < ApplicationRecord\n  self.table_name = "analytics.mart_growth"\nend',
        'class B < ApplicationRecord\n  self.table_name = "ingest.work_item"\nend',
        'class C < ApplicationRecord\n  self.table_name = "app.sync_request"\nend',
        'class D < ApplicationRecord\n  self.table_name   =   "analytics.dim_member"\nend',
    ]
    assert verify_views.declared_relations(texts) == [
        "analytics.dim_member", "analytics.mart_growth", "ingest.work_item",
    ]


def test_declared_relations_dedupes_and_ignores_files_without_a_table_name():
    texts = ['self.table_name = "analytics.x"', 'self.table_name = "analytics.x"', "def foo; end"]
    assert verify_views.declared_relations(texts) == ["analytics.x"]


def test_rails_relations_reads_the_real_model_tree():
    relations = verify_views.rails_relations()
    assert "analytics.fct_ingest_run" in relations
    assert "analytics.mart_channel_bands" in relations
    assert all(r.startswith(("analytics.", "ingest.")) for r in relations)


class FakeConn:
    def __init__(self, present):
        self.present = set(present)

    def execute(self, sql, params):
        schema, name = params
        return FakeRow(f"{schema}.{name}" in self.present)


class FakeRow:
    def __init__(self, found):
        self.found = found

    def fetchone(self):
        return (1,) if self.found else None


def test_missing_lists_only_relations_the_database_lacks():
    conn = FakeConn(present={"analytics.a", "analytics.b"})
    assert verify_views.missing(conn, ["analytics.a", "analytics.b", "analytics.c"]) == ["analytics.c"]
    assert verify_views.missing(conn, ["analytics.a"]) == []

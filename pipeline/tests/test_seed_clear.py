from seed.emit import (
    DEPENDENTS,
    DETACH,
    SEED_PREDICATES,
    SEEDED_TABLES,
    going,
    release,
)


class Cur:
    def __init__(self):
        self.ran = []

    def execute(self, sql, params=None):
        self.ran.append(sql)


def test_every_owned_child_goes_before_its_parent():
    for child, _, parent in DEPENDENTS:
        if child in SEEDED_TABLES and parent in SEEDED_TABLES:
            assert SEEDED_TABLES.index(child) < SEEDED_TABLES.index(parent), (
                f"{child} must be cleared before {parent}"
            )


def test_a_child_of_a_seeded_row_is_taken_even_when_it_is_not_seeded():
    cur = Cur()
    release(cur)

    citations = [sql for sql in cur.ran if "fd.case_citations" in sql]
    assert citations, "citations on a seeded message must be released"
    assert "DELETE FROM fd.case_citations" in citations[0]
    assert SEED_PREDICATES["fd.thread_messages"] in citations[0], (
        "it must key off the messages going away, not off who flagged it"
    )


def test_chat_on_a_seeded_case_is_released():
    cur = Cur()
    release(cur)

    assert any(
        "DELETE FROM fd.case_chat" in sql and SEED_PREDICATES["fd.cases"] in sql
        for sql in cur.ran
    ), "fd.case_chat restricts fd.cases, so it has to go first"


def test_a_nullable_reference_is_detached_not_deleted():
    cur = Cur()
    release(cur)

    for child, column, _ in DETACH:
        assert any(
            sql.startswith(f"UPDATE {child} SET {column} = NULL") for sql in cur.ran
        ), f"{child}.{column} is nullable, so the row itself survives"


def test_detaching_happens_before_deleting():
    cur = Cur()
    release(cur)

    first_delete = next(i for i, sql in enumerate(cur.ran) if sql.startswith("DELETE"))
    last_update = max(i for i, sql in enumerate(cur.ran) if sql.startswith("UPDATE"))
    assert last_update < first_delete


def test_force_takes_the_whole_parent_table():
    assert going("fd.cases", force=False) != going("fd.cases", force=True)
    assert going("fd.cases", force=True) == "SELECT id FROM fd.cases"
    assert SEED_PREDICATES["fd.cases"] in going("fd.cases", force=False)

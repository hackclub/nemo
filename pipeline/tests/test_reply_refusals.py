import inspect

from ingest import channel_replies_pull
from lib import faults, work


def recorded(fault):
    return f"{fault.name}: {fault.detail}"


def test_gave_way_stores_the_fault_class_with_the_detail():
    body = inspect.getsource(channel_replies_pull.gave_way)
    assert 'f"{fault.name}: {fault.detail}"' in body


def test_an_entity_fault_is_written_where_the_revive_guard_can_see_it():
    gone = faults.fault("entity", "channel_not_found")
    assert recorded(gone)[:7] == "entity:"


def test_the_web_client_sentence_alone_defeats_both_guards():
    said = (
        "The request to the Slack API failed. (url: https://slack.com/api/conversations.replies) "
        "The server responded with: {'ok': False, 'error': 'channel_not_found'}"
    )
    assert said[:7] != "entity:"
    assert said not in work.REFUSALS

    gone = faults.fault("entity", said)
    assert recorded(gone)[:7] == "entity:"


def test_a_forgiven_fault_stays_revivable():
    slow = faults.fault("contended", "canceling statement due to lock timeout")
    assert recorded(slow)[:7] != "entity:"
    assert slow.name in channel_replies_pull.FORGIVEN


def test_the_attempt_cap_still_reads_the_bare_fault_name():
    body = inspect.getsource(channel_replies_pull.gave_way)
    assert "fault.name in FORGIVEN" in body

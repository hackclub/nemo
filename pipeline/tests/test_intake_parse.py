from bot.engine import parse


def test_digest_ignores_key_order():
    a = parse.digest("hi", [{"type": "section", "text": "x"}], None)
    b = parse.digest("hi", [{"text": "x", "type": "section"}], None)
    assert a == b


def test_digest_treats_empty_and_absent_alike():
    assert parse.digest("", None, None) == parse.digest(None, [], [])


def test_digest_changes_with_the_text():
    assert parse.digest("hi", None, None) != parse.digest("hi there", None, None)


def test_link_target_pulls_channel_and_ts():
    url = "https://hackclub.slack.com/archives/C0266FRGT/p1700000000123456"
    assert parse.link_target(url) == ("C0266FRGT", "1700000000.123456", None)


def test_a_link_to_a_reply_carries_the_thread_it_belongs_to():
    url = ("https://hackclub.slack.com/archives/C0BE6N4G2BA/p1787569148773329"
           "?thread_ts=1787569009.909839&cid=C0BE6N4G2BA")
    assert parse.link_target(url) == (
        "C0BE6N4G2BA", "1787569148.773329", "1787569009.909839"
    )


def test_slack_escapes_the_ampersand_and_it_is_still_read():
    url = ("https://hackclub.slack.com/archives/C0BE6N4G2BA/p1787569148773329"
           "?thread_ts=1787569009.909839&amp;cid=C0BE6N4G2BA")
    assert parse.link_target(url)[2] == "1787569009.909839"


def test_a_pasted_reply_link_attaches_the_thread_not_the_reply():
    said = ("<https://hackclub.slack.com/archives/C0BE6N4G2BA/p1787569148773329"
            "?thread_ts=1787569009.909839&amp;cid=C0BE6N4G2BA|"
            "https://hackclub.slack.com/archives/C0BE6N4G2BA/p1787569148773329"
            "?thread_ts=1787569009.909839&amp;cid=C0BE6N4G2BA>"
            "\n\ni'd like to report it?")
    share = parse.shares({"text": said, "attachments": []})[0]

    assert share["source_ts"] == "1787569148.773329"
    assert share["source_thread_ts"] == "1787569009.909839"
    assert share["kind"] == "link"
    assert share["is_reachable"] is False


def test_a_cid_that_is_not_a_thread_ts_is_ignored():
    url = ("https://hackclub.slack.com/archives/C0266FRGT/p1700000000123456"
           "?cid=C0266FRGT&x=1")
    assert parse.link_target(url)[2] is None


def test_link_target_ignores_anything_else():
    assert parse.link_target("https://example.com/nope") is None
    assert parse.link_target(None) is None


def test_forwarded_message_keeps_its_source():
    event = {
        "text": "look at this",
        "attachments": [
            {
                "is_share": True,
                "is_msg_unfurl": True,
                "channel_id": "C111",
                "channel_name": "lounge",
                "ts": "1700000000.123456",
                "author_id": "U999",
                "text": "the awful thing",
                "from_url": "https://hackclub.slack.com/archives/C111/p1700000000123456",
            }
        ],
    }
    share = parse.shares(event)[0]
    assert share["kind"] == "forward"
    assert share["source_channel_id"] == "C111"
    assert share["source_ts"] == "1700000000.123456"
    assert share["source_author_user_id"] == "U999"
    assert share["source_channel_name"] == "lounge"


def test_unfurl_is_not_a_forward():
    event = {
        "attachments": [
            {
                "is_msg_unfurl": True,
                "channel_id": "C111",
                "ts": "1700000000.123456",
            }
        ]
    }
    assert parse.shares(event)[0]["kind"] == "unfurl"


def test_a_pasted_link_with_no_attachment_still_counts():
    event = {"text": "see https://hackclub.slack.com/archives/C222/p1699999999000100"}
    share = parse.shares(event)[0]
    assert share["kind"] == "link"
    assert share["source_channel_id"] == "C222"
    assert share["source_ts"] == "1699999999.000100"


def test_a_link_slack_already_unfurled_is_not_recorded_twice():
    event = {
        "text": "see https://hackclub.slack.com/archives/C222/p1699999999000100",
        "attachments": [
            {
                "is_msg_unfurl": True,
                "channel_id": "C222",
                "ts": "1699999999.000100",
            }
        ],
    }
    found = parse.shares(event)
    assert len(found) == 1
    assert found[0]["kind"] == "unfurl"


def test_several_forwards_in_one_message():
    event = {
        "attachments": [
            {"is_share": True, "channel_id": "C1", "ts": "1.1"},
            {"is_share": True, "channel_id": "C2", "ts": "2.2"},
        ]
    }
    assert len(parse.shares(event)) == 2


def test_plain_attachments_are_not_shares():
    event = {"attachments": [{"text": "just a colour bar", "color": "#eee"}]}
    assert parse.shares(event) == []


def test_a_hosted_image_is_pending_a_fetch():
    event = {
        "files": [
            {
                "id": "F1",
                "name": "shot.png",
                "mimetype": "image/png",
                "mode": "hosted",
                "size": 40311,
                "original_w": "1284",
                "original_h": "812",
                "url_private": "https://files.slack.com/x",
                "created": 1700000000,
            }
        ]
    }
    item = parse.files(event)[0]
    assert item["fetch_state"] == "pending"
    assert item["original_w"] == 1284
    assert item["created_at"].year == 2023


def test_an_external_file_is_skipped_not_fetched():
    event = {
        "files": [
            {
                "id": "F2",
                "mode": "external",
                "is_external": True,
                "external_type": "gdrive",
                "external_url": "https://drive.google.com/x",
            }
        ]
    }
    item = parse.files(event)[0]
    assert item["fetch_state"] == "skipped"
    assert item["is_external"]


def test_a_tombstoned_file_is_gone():
    event = {"files": [{"id": "F3", "is_tombstoned": True, "url_private": "https://x"}]}
    assert parse.files(event)[0]["fetch_state"] == "gone"


def test_a_file_hidden_by_the_plan_limit_is_gone():
    event = {"files": [{"id": "F4", "is_hidden_by_limit": True, "url_private": "https://x"}]}
    assert parse.files(event)[0]["fetch_state"] == "gone"


def test_a_canvas_keeps_its_undocumented_mode():
    event = {"files": [{"id": "F5", "mode": "space"}]}
    item = parse.files(event)[0]
    assert item["mode"] == "space"
    assert item["fetch_state"] == "skipped"


def test_the_same_file_twice_in_one_message_is_recorded_once():
    event = {"files": [{"id": "F6", "url_private": "https://x"}, {"id": "F6"}]}
    assert len(parse.files(event)) == 1


def test_files_without_an_id_are_dropped():
    event = {"files": [{"name": "nameless"}, None]}
    assert parse.files(event) == []


def test_no_files_and_no_attachments_is_empty():
    assert parse.files({}) == []
    assert parse.shares({}) == []


def unfurl(**over):
    said = {"is_msg_unfurl": True, "author_id": "UMILO", "text": "the awful line"}
    said.update(over)
    return said


REPLY = ("https://hackclub.slack.com/archives/C09TTRZH94Z/p1787569865339089"
         "?thread_ts=1787568364.974219&amp;cid=C09TTRZH94Z")
ROOT = "https://hackclub.slack.com/archives/C09TTRZH94Z/p1787568364974219"


def test_one_paste_is_one_share_however_slack_stamps_the_unfurl():
    for ts in ("1787569865.339089", "1787568364.974219", None):
        event = {"text": f"<{REPLY}|{REPLY}>", "attachments": [
            unfurl(channel_id="C09TTRZH94Z", ts=ts, permalink=REPLY)]}
        found = parse.shares(event)

        assert len(found) == 1, f"a ts of {ts} split one paste in two"
        assert found[0]["is_reachable"] is True
        assert found[0]["source_body"] == "the awful line"


def test_the_merged_share_keeps_the_words_and_gains_the_thread():
    event = {"text": f"<{REPLY}|{REPLY}>", "attachments": [
        unfurl(channel_id="C09TTRZH94Z", permalink=REPLY)]}
    found = parse.shares(event)[0]

    assert found["source_author_user_id"] == "UMILO"
    assert found["source_ts"] == "1787569865.339089"
    assert found["source_thread_ts"] == "1787568364.974219"


def test_two_different_messages_stay_two_shares():
    other = REPLY.replace("p1787569865339089", "p1787569999000000")
    found = parse.shares({"text": f"<{REPLY}|{REPLY}> and {other}", "attachments": []})

    assert [s["source_ts"] for s in found] == ["1787569865.339089", "1787569999.000000"]


def test_a_forward_of_the_root_does_not_swallow_a_link_to_a_reply():
    event = {"text": f"<{REPLY}|{REPLY}>", "attachments": [
        unfurl(is_share=True, is_msg_unfurl=False, channel_id="C09TTRZH94Z",
               ts="1787568364.974219", permalink=ROOT)]}
    found = parse.shares(event)

    assert [s["kind"] for s in found] == ["forward", "link"]


def test_a_richer_shape_wins_when_two_are_merged():
    event = {"text": f"<{REPLY}|{REPLY}>", "attachments": [
        unfurl(is_share=True, is_msg_unfurl=False, channel_id="C09TTRZH94Z", permalink=REPLY)]}

    assert parse.shares(event)[0]["kind"] == "forward"

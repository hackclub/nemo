from bot.nemo.views.lines import slack_link


def ref(case_id, url_of, slack_of):
    url = url_of(case_id)
    label = f"Case #{case_id}"
    linked = f"<{url}|{label}>" if url else label
    return linked + slack_link(slack_of(case_id))


def line(case_id, main_id, url_of, slack_of):
    text = ref(case_id, url_of, slack_of)
    return f"{text} · merged into {ref(main_id, url_of, slack_of)}" if main_id else text


def message(case_ids, lines):
    return {
        "text": ", ".join(f"Case #{case_id}" for case_id in case_ids),
        "blocks": [{"type": "context", "elements": [{"type": "mrkdwn", "text": "\n".join(lines)}]}],
    }

import yaml

from bot.engine import richtext
from lib.paths import CATEGORIES_FILE

MENU = "case_more"

PEOPLE = "case_people"
CATEGORY = "case_category"
NOTE = "case_note"
HAND_BACK = "case_hand_back"
REVERSE = "case_reverse"

WHAT = "category_what"
SAID = "note_said"

NOTE_LIMIT = 5000
TITLE_LIMIT = 24
NO_LABEL = " "

LABELS = None


def categories():
    global LABELS
    if LABELS is None:
        LABELS = yaml.safe_load(CATEGORIES_FILE.read_text())["categories"]
    return LABELS


def option(text, value):
    return {"text": {"type": "plain_text", "text": text}, "value": value}


def choices(case, mine):
    out = [option("People", PEOPLE)]
    if not case.get("category_key"):
        out.append(option("Set the violation", CATEGORY))
    out.append(option("Leave a note", NOTE))
    if case.get("live_actions"):
        out.append(option("Reverse an action", REVERSE))
    if mine:
        out.append(option("Hand it back", HAND_BACK))
    return out


def menu(case, mine):
    picks = choices(case, mine)
    if not picks:
        return None

    return {
        "type": "overflow",
        "action_id": MENU,
        "options": [
            option(pick["text"]["text"], f"{pick['value']}:{case['case_id']}")
            for pick in picks
        ],
    }


def asked(value):
    verb, _, case_id = (value or "").rpartition(":")
    return verb, int(case_id) if case_id.isdigit() else None


def category_view(case_id):
    return {
        "type": "modal",
        "callback_id": CATEGORY,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Violation · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Set it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            {
                "type": "input",
                "block_id": WHAT,
                "label": {"type": "plain_text", "text": NO_LABEL},
                "element": {
                    "type": "static_select",
                    "action_id": WHAT,
                    "options": [
                        option(label, key) for key, label in categories().items()
                    ],
                },
            },
        ],
    }


def note_view(case_id):
    return {
        "type": "modal",
        "callback_id": NOTE,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Note · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Keep it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            {
                "type": "input",
                "block_id": SAID,
                "label": {"type": "plain_text", "text": NO_LABEL},
                "element": {
                    "type": "rich_text_input",
                    "action_id": SAID,
                    "min_lines": 3,
                    "placeholder": {
                        "type": "plain_text",
                        "text": "what you found, what you did",
                    },
                },
            }
        ],
    }


def what_picked(view_state):
    chosen = view_state.get("values", {}).get(WHAT, {}).get(WHAT, {}).get("selected_option")
    return (chosen or {}).get("value")


def said_picked(view_state):
    said = view_state.get("values", {}).get(SAID, {}).get(SAID, {}).get("rich_text_value")
    return richtext.flatten(said)[:NOTE_LIMIT]


def note_objection(said):
    if not said:
        return {SAID: "Write something first."}
    return None


def category_label(key):
    return categories().get(key, (key or "").replace("_", " "))

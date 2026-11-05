from bot.nemo.views import edit

CALLBACK = "case_merge"
TARGET = "merge_keep"
DUPLICATES = "merge_fold"

OPTION_LIMIT = 100
TEXT_LIMIT = 75


def label(case_id, category_key, names):
    parts = [str(case_id), edit.category_label(category_key) if category_key else None, names]
    return ", ".join(part for part in parts if part)[:TEXT_LIMIT]


def option(one):
    case_id, category_key, names = one
    return {"text": {"type": "plain_text", "text": label(case_id, category_key, names)},
            "value": str(case_id)}


def options(cases):
    return [option(one) for one in cases[:OPTION_LIMIT]]


def build_view(cases, target=None, duplicates=()):
    by_id = {one["value"]: one for one in options(cases)}

    target_select = {
        "type": "external_select",
        "action_id": TARGET,
        "placeholder": {"type": "plain_text", "text": "Select a case"},
        "min_query_length": 0,
    }
    if str(target) in by_id:
        target_select["initial_option"] = by_id[str(target)]

    duplicates_select = {
        "type": "multi_external_select",
        "action_id": DUPLICATES,
        "placeholder": {"type": "plain_text", "text": "Select cases"},
        "min_query_length": 0,
    }
    selected_options = [by_id[str(one)] for one in duplicates if str(one) in by_id]
    if selected_options:
        duplicates_select["initial_options"] = selected_options

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "title": {"type": "plain_text", "text": "Merge cases"},
        "submit": {"type": "plain_text", "text": "Merge"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            {"type": "input", "block_id": TARGET,
             "label": {"type": "plain_text", "text": "Target case"}, "element": target_select},
            {"type": "input", "block_id": DUPLICATES,
             "label": {"type": "plain_text", "text": "Duplicates"}, "element": duplicates_select},
        ],
    }


def submitted_values(state):
    values = state.get("values", {})
    target_id = (values.get(TARGET, {}).get(TARGET, {}).get("selected_option") or {}).get("value")
    duplicate_options = values.get(DUPLICATES, {}).get(DUPLICATES, {}).get("selected_options") or []
    return {
        "target": int(target_id) if target_id else None,
        "duplicates": [int(one["value"]) for one in duplicate_options],
    }


def validation_errors(values):
    if not values.get("target"):
        return {TARGET: "Select a case"}
    if not values.get("duplicates"):
        return {DUPLICATES: "Select a duplicate"}
    if values["target"] in values["duplicates"]:
        return {DUPLICATES: "A case cannot be merged into itself."}
    return None


def parse_case_ids(text):
    numbers = []
    for word in (text or "").replace(",", " ").split():
        word = word.lstrip("#")
        if word.isdigit():
            numbers.append(int(word))
    target_id, *duplicate_ids = numbers or [None]
    return target_id, duplicate_ids

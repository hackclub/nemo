from bot.nemo.views import edit, lengths, resolve

MENU_CLAIM = "case_menu_claim"
MENU_ASSIGN = "case_menu_assign"
MENU_UNASSIGN = "case_menu_unassign"
MENU_NOTE = "case_menu_note"
MENU_MERGE = "case_menu_merge"
MENU_CATEGORY = "case_menu_category"

MENU_CALLBACK = "case_menu"
ASSIGN_CALLBACK = "case_assign"
UNASSIGN_CALLBACK = "case_unassign"
NOTE_CALLBACK = "case_note"
CATEGORY_CALLBACK = "case_category"
RESOLVE_CALLBACK = "case_resolve"

ASSIGN_TO = "assign_to"
UNASSIGN_FROM = "unassign_from"
NOTE_TARGET = "note_target"
NOTE_MEMBER = "note_member"
NOTE_TEXT = "note_text"
CATEGORY_KEY = "category_key"
RESOLUTION = "resolution"
REPORTER_MESSAGE = "reporter_message"

ON_CASE = "case"
ON_MEMBER = "member"

TEXT_LIMIT = 2000
OPTION_LIMIT = 75
EXCLUDED_RESOLUTIONS = ("duplicate",)

plain = lengths.plain


def button(action_id, text, case_id, style=None):
    built = {"type": "button", "action_id": action_id, "text": plain(text), "value": str(case_id)}
    if style:
        built["style"] = style
    return built


def modal(callback_id, case_id, title, blocks, submit=None):
    built = {
        "type": "modal",
        "callback_id": callback_id,
        "private_metadata": str(case_id),
        "title": plain(title),
        "close": plain("Cancel" if submit else "Close"),
        "blocks": blocks,
    }
    if submit:
        built["submit"] = plain(submit)
    return built


def field(block_id, label, element, optional=False, dispatch=False):
    built = {"type": "input", "block_id": block_id, "label": plain(label), "element": element}
    if dispatch:
        built["dispatch_action"] = True
    if optional:
        built["optional"] = True
    return built


def option(text, value):
    return {"text": plain(text[:OPTION_LIMIT]), "value": value}


def assignee_text(assignees):
    return ", ".join(f"<@{one}>" for one in assignees) if assignees else "None"


def more_view(case_id, assignees, url=None, notice=None):
    claim_style = None if assignees else "primary"
    people_row = [button(MENU_CLAIM, "Claim", case_id, claim_style), button(MENU_ASSIGN, "Assign", case_id)]
    if assignees:
        people_row.append(button(MENU_UNASSIGN, "Unassign", case_id, "danger"))
    record_row = [button(MENU_NOTE, "Note", case_id), button(MENU_MERGE, "Merge", case_id),
                  button(MENU_CATEGORY, "Category", case_id)]
    blocks = []
    if notice:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": notice}]})
    blocks += [
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*Assignees*\n{assignee_text(assignees)}"}},
        {"type": "actions", "elements": people_row},
        {"type": "divider"},
        {"type": "actions", "elements": record_row},
    ]
    if url:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": f"<{url}|Open in Fire Engine>"}]})
    return modal(MENU_CALLBACK, case_id, f"Case {case_id}", blocks)


def assign_view(case_id, assignees=()):
    element = {"type": "multi_users_select", "action_id": ASSIGN_TO, "placeholder": plain("Select members")}
    if assignees:
        element["initial_users"] = list(assignees)
    return modal(ASSIGN_CALLBACK, case_id, f"Assign case {case_id}",
                 [field(ASSIGN_TO, "Assignees", element)], "Assign")


def unassign_view(case_id, assignees):
    element = {
        "type": "multi_static_select",
        "action_id": UNASSIGN_FROM,
        "placeholder": plain("Select members"),
        "options": [option(name, user_id) for user_id, name in assignees],
    }
    return modal(UNASSIGN_CALLBACK, case_id, f"Unassign case {case_id}",
                 [field(UNASSIGN_FROM, "Assignees", element)], "Unassign")


def note_targets(case_id):
    return [option(f"Case {case_id}", ON_CASE), option("Member", ON_MEMBER)]


def note_view(case_id, on_member=False, member=None, text=None):
    targets = note_targets(case_id)
    blocks = [field(
        NOTE_TARGET, "Attach to",
        {"type": "radio_buttons", "action_id": NOTE_TARGET, "options": targets,
         "initial_option": targets[1 if on_member else 0]},
        dispatch=True,
    )]
    if on_member:
        element = {"type": "users_select", "action_id": NOTE_MEMBER, "placeholder": plain("Select a member")}
        if member:
            element["initial_user"] = member
        blocks.append(field(NOTE_MEMBER, "Member", element))
    note_element = {"type": "plain_text_input", "action_id": NOTE_TEXT, "multiline": True,
                    "max_length": TEXT_LIMIT}
    if text:
        note_element["initial_value"] = text
    blocks.append(field(NOTE_TEXT, "Note", note_element))
    return modal(NOTE_CALLBACK, case_id, "Note", blocks, "Add")


def category_view(case_id, current_key=None):
    options = [option(label, key) for key, label in edit.categories().items()]
    element = {"type": "static_select", "action_id": CATEGORY_KEY,
               "placeholder": plain("Select a category"), "options": options}
    selected = [one for one in options if one["value"] == current_key]
    if selected:
        element["initial_option"] = selected[0]
    return modal(CATEGORY_CALLBACK, case_id, "Category", [field(CATEGORY_KEY, "Category", element)], "Save")


def resolution_options():
    return [option(row["label"], key) for key, row in resolve.table()["resolutions"].items()
            if key not in EXCLUDED_RESOLUTIONS]


def resolve_view(case_id, resolution=None, message=None):
    options = resolution_options()
    selected = [one for one in options if one["value"] == resolution]
    resolution_element = {"type": "static_select", "action_id": RESOLUTION,
                          "placeholder": plain("Select a resolution"), "options": options}
    if selected:
        resolution_element["initial_option"] = selected[0]
    message_element = {
        "type": "plain_text_input", "action_id": REPORTER_MESSAGE, "multiline": True,
        "max_length": TEXT_LIMIT,
        "initial_value": resolve.default_message() if message is None else message,
    }
    blocks = [
        field(RESOLUTION, "Resolution", resolution_element),
        field(REPORTER_MESSAGE, "Message to reporter", message_element, optional=True),
    ]
    return modal(RESOLVE_CALLBACK, case_id, f"Resolve case {case_id}", blocks, "Resolve")


def entered(state, block_id):
    return (state.get("values", {}).get(block_id) or {}).get(block_id) or {}


def selected_users(state, block_id):
    return list(entered(state, block_id).get("selected_users") or [])


def selected_values(state, block_id):
    return [one["value"] for one in entered(state, block_id).get("selected_options") or []]


def selected_value(state, block_id):
    return (entered(state, block_id).get("selected_option") or {}).get("value")


def typed(state, block_id):
    return (entered(state, block_id).get("value") or "").strip()


def assign_values(state):
    return selected_users(state, ASSIGN_TO)


def unassign_values(state):
    return selected_values(state, UNASSIGN_FROM)


def note_values(state):
    return {
        "on_member": selected_value(state, NOTE_TARGET) == ON_MEMBER,
        "member": entered(state, NOTE_MEMBER).get("selected_user"),
        "text": typed(state, NOTE_TEXT),
    }


def category_value(state):
    return selected_value(state, CATEGORY_KEY)


def resolve_values(state):
    message = typed(state, REPORTER_MESSAGE)
    return {
        "resolution": selected_value(state, RESOLUTION),
        "member_note": None,
        "message": message or None,
        "notify_reporter": bool(message),
    }

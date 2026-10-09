import yaml

from lib.paths import AUDIT_ACTIONS_FILE

PLACEHOLDERS = ("{actor}", "{entity}")


def catalogue():
    return yaml.safe_load(AUDIT_ACTIONS_FILE.read_text())


def categories(held=None):
    return (held or catalogue())["categories"]


def entry(action, held=None):
    found = (held or catalogue())["actions"].get(action)
    if found:
        return found
    named = str(action or "").replace("_", " ").replace(".", " ")
    return {"category": None, "label": named, "sentence": "{actor}: " + named}


def unknown(actions, held=None):
    known = (held or catalogue())["actions"]
    return sorted({one for one in actions if one and one not in known})


def slim_actions(held=None):
    return sorted(name for name, one in (held or catalogue())["actions"].items() if one.get("slim"))

import yaml

from lib.paths import SOURCES_FILE

DECLARED = ("cadence", "window", "guard", "resume", "retention", "writes", "feeds")


def _load():
    return yaml.safe_load(SOURCES_FILE.read_text())


TABLE = _load()
SOURCES = TABLE["sources"]
KEYS = tuple(SOURCES)
CADENCES = tuple(TABLE["cadences"])
GUARDS = tuple(TABLE["guards"])
RESUMES = tuple(TABLE["resumes"])
RETENTIONS = tuple(TABLE["retentions"])


class Unknown(KeyError):
    """No source in db/sources.yml carries this key"""


def source(key):
    try:
        return SOURCES[key]
    except KeyError:
        raise Unknown(f"{key} is not a source") from None


def says(key, field):
    return source(key)[field]


def limit(key, name):
    limits = source(key).get("limits") or {}
    if name not in limits:
        raise Unknown(f"{key} declares no {name} limit")
    return limits[name]


def clamped(key, name, value):
    bounds = limit(key, name)
    if value is None:
        return bounds["default"]
    return max(bounds["min"], min(bounds["max"], int(value)))


def prune_floor(key):
    return source(key).get("prune_floor")


def runs_as(key):
    return source(key).get("runs_as") or [key]

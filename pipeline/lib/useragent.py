import re

UNKNOWN = None

SLACK_DESKTOP = re.compile(r"Slack_SSB/([\d.]+)|Slack/([\d.]+).*Electron", re.IGNORECASE)
SLACK_MOBILE = re.compile(r"\bslack/([\d.]+)\s*\(([^;)]+);\s*([^;)]+)", re.IGNORECASE)
SLACK_SDK = re.compile(
    r"slackclient/([\d.]+)|python-slack-sdk|slack[_/:-]bolt|@slack[/:]", re.IGNORECASE
)
SLACK_IOS = re.compile(r"com\.tinyspeck\.chatlyio(?:\.\w+)?/([\d.]+)", re.IGNORECASE)
HUDDLE = re.compile(r"HuddlePhone/([\d.]+)", re.IGNORECASE)
API_CLIENT = re.compile(r"\bApiApp\b|Slack Ruby Client|\bPython/[\d.]+", re.IGNORECASE)

RUNTIMES = (
    ("Bun", re.compile(r"\bBun/([\d.]+)", re.IGNORECASE)),
    ("Deno", re.compile(r"\bDeno/([\d.]+)", re.IGNORECASE)),
    ("Node", re.compile(r"\bnode(?:\.js)?/v?([\d.]+)", re.IGNORECASE)),
    ("aiohttp", re.compile(r"\baiohttp/([\d.]+)", re.IGNORECASE)),
    ("httpx", re.compile(r"\bpython-httpx/([\d.]+)", re.IGNORECASE)),
    ("requests", re.compile(r"\bpython-requests/([\d.]+)", re.IGNORECASE)),
    ("urllib", re.compile(r"\bPython-urllib/([\d.]+)", re.IGNORECASE)),
    ("curl", re.compile(r"\bcurl/([\d.]+)", re.IGNORECASE)),
    ("Go", re.compile(r"\bGo-http-client/([\d.]+)", re.IGNORECASE)),
    ("okhttp", re.compile(r"\bokhttp/([\d.]+)", re.IGNORECASE)),
    ("axios", re.compile(r"\baxios/([\d.]+)", re.IGNORECASE)),
)

BROWSERS = (
    ("Edge", re.compile(r"Edg(?:e|A|iOS)?/([\d.]+)")),
    ("Opera", re.compile(r"OPR/([\d.]+)")),
    ("Firefox", re.compile(r"(?:Firefox|FxiOS)/([\d.]+)")),
    ("Safari", re.compile(r"Version/([\d.]+).*Safari/")),
    ("Chrome", re.compile(r"(?:CriOS|Chrome)/([\d.]+)")),
)

SYSTEMS = (
    ("iPadOS", re.compile(r"iPad; CPU OS ([\d_]+)")),
    ("iOS", re.compile(r"\biOS ([\d.]+)|i(?:Phone|Pod)[^)]*CPU[^)]*OS ([\d_]+)")),
    ("Android", re.compile(r"Android ([\d.]+)")),
    ("macOS", re.compile(r"Mac OS X ([\d_.]+)")),
    ("Windows", re.compile(r"Windows NT ([\d.]+)")),
    ("Linux", re.compile(r"\bLinux\b")),
)

WINDOWS_NAMES = {"10.0": "10 or 11", "6.3": "8.1", "6.2": "8", "6.1": "7"}


def version(raw):
    return (raw or "").replace("_", ".").strip(".")


def named(family, raw):
    return f"{family} {raw}" if raw else family


def windows(raw):
    found = version(raw)
    return named("Windows", WINDOWS_NAMES.get(found, found))


def system(ua):
    for family, pattern in SYSTEMS:
        found = pattern.search(ua)
        if not found:
            continue
        if family == "Windows":
            return windows(found.group(1))
        raw = next((one for one in found.groups() if one), "")
        return named(family, version(raw))
    return UNKNOWN


def browser(ua):
    for family, pattern in BROWSERS:
        found = pattern.search(ua)
        if found:
            return named(family, version(found.group(1)))
    return UNKNOWN


def app(ua):
    found = SLACK_MOBILE.search(ua)
    if found:
        maker = found.group(2).strip()
        if not maker:
            return "Slack mobile"
        family = "Slack Android" if "android" in ua.lower() else "Slack mobile"
        return named(family, version(found.group(1)))

    found = SLACK_DESKTOP.search(ua)
    if found:
        raw = next((one for one in found.groups() if one), "")
        return named("Slack Desktop", version(raw))

    found = SLACK_IOS.search(ua)
    if found:
        return named("Slack iOS", version(found.group(1)))

    if SLACK_SDK.search(ua):
        return "Slack SDK"

    found = HUDDLE.search(ua)
    if found:
        return named("Slack huddle", version(found.group(1)))

    seen = browser(ua)
    if seen:
        return seen

    for family, pattern in RUNTIMES:
        found = pattern.search(ua)
        if found:
            return named(family, version(found.group(1)))

    return UNKNOWN


def device(ua):
    found = SLACK_MOBILE.search(ua)
    if not found:
        return UNKNOWN
    return found.group(2).strip() or UNKNOWN


def api_client(ua):
    raw = (ua or "").strip()
    if not raw:
        return False
    if SLACK_SDK.search(raw) or API_CLIENT.search(raw):
        return True
    return any(pattern.search(raw) for _family, pattern in RUNTIMES)


def parse(ua):
    raw = (ua or "").strip()
    if not raw:
        return {"ua": UNKNOWN, "ua_app": UNKNOWN, "ua_os": UNKNOWN}

    return {"ua": raw, "ua_app": app(raw), "ua_os": system(raw) or device(raw)}

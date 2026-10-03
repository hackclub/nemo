MARKUP = [
    "<script>alert(1)</script>",
    "\"><img src=x onerror=alert(1)>",
    "<svg/onload=alert(1)>",
    "javascript:alert(1)",
    "<iframe src=//evil.test></iframe>",
    "</td></tr><tr><td>injected",
    "<b>bold</b> &amp; &lt;escaped&gt;",
]

TEMPLATES = [
    "{{7*7}}",
    "${7*7}",
    "<%= 7*7 %>",
    "#{7*7}",
    "{{constructor.constructor('alert(1)')()}}",
]

INJECTION = [
    "'; drop table raw.member_dim; --",
    "' or 1=1 --",
    "%' union select null,null --",
    "\\'; select pg_sleep(10); --",
]

UNICODE = [
    "‮gnitset-ltr",
    "zero​width​spaces",
    "\U0001f4a9\U0001f680\U0001f9e0",
    "Á́́́combining",
    "Ｆｕｌｌｗｉｄｔｈ",
    "\\x00-literal-null-text",
]

PATHS = [
    "../../etc/passwd",
    "....//....//etc/shadow",
    "file:///etc/hostname",
    "\\\\evil.test\\share",
]

LONG = ["overflow-" + "x" * 300, "y" * 1200]

WHITESPACE = ["line\nbreak", "tab\tseparated", "   padded   ", ""]

PAYLOADS = MARKUP + TEMPLATES + INJECTION + UNICODE + PATHS + LONG + WHITESPACE

SHORT_NAMES = ["a", "b", "c", "d", "e", "de", "hc", "ai"]

POISON_SHARE = 0.02


def as_channel_name(value):
    return value.replace(" ", "-").replace("\n", "").replace("\t", "") or "empty-name"


def payload(rng):
    return PAYLOADS[rng.randrange(len(PAYLOADS))]


def poison_channels(rng, channels):
    if not channels:
        return 0
    touched = 0
    for i, name in enumerate(SHORT_NAMES):
        if i < len(channels):
            channels[i].name = name
            touched += 1
    remaining = channels[len(SHORT_NAMES):]
    for i, value in enumerate(PAYLOADS):
        if i < len(remaining):
            remaining[i].name = as_channel_name(value)
            touched += 1
    for channel in remaining[len(PAYLOADS):]:
        if rng.random() < POISON_SHARE:
            channel.name = as_channel_name(f"{channel.name}{payload(rng)}")
            touched += 1
    return touched


def display_name(rng, user_id, hostile):
    if hostile and rng.random() < 0.3:
        return payload(rng)
    return f"member {user_id[-4:]}"


def reason(rng, base, hostile):
    if hostile and rng.random() < 0.3:
        return f"{base}: {payload(rng)}"
    return base

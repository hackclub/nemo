import random
from datetime import timedelta

MEMBER_COLUMNS = [
    "user_id", "handle", "display_name", "title", "pronouns", "avatar_url", "avatar_hash",
    "tz", "tz_offset", "enterprise_id", "team_ids", "is_bot", "is_deleted", "is_admin",
    "is_owner", "is_restricted", "is_ultra_restricted", "profile_updated_at",
]

IDENTITY_COLUMNS = ["user_id", "real_name", "first_name", "last_name", "email"]

SEED_ENTERPRISE = "ESEED00001"
SEED_TEAM = "TSEED00001"
SEED_EMAIL_DOMAIN = "example.invalid"

GIVEN_NAMES = (
    "ada avery bo cyrus dara elio fen gia hal iris jun kai lena milo nadia orla pax quinn "
    "rune sam tess uma vero wren xio yuki zev"
).split()

FAMILY_NAMES = (
    "ainsley brook chen delgado eskildsen faraday gallo hollis ibarra jensen kovac lindqvist "
    "moreno nakamura okafor pereira quiroga ridley sokolov tanaka ueda vasquez whitfield "
    "yamada zielinski"
).split()

PRONOUN_POOL = ("", "", "she/her", "he/him", "they/them", "she/they", "he/they")

TIMEZONES = (
    ("America/New_York", -14400),
    ("America/Los_Angeles", -25200),
    ("Europe/London", 3600),
    ("Africa/Cairo", 10800),
    ("Asia/Kolkata", 19800),
    ("Australia/Sydney", 36000),
)

TITLES = (
    "", "", "", "high school | building things", "ysws enjoyer", "fd | ask me anything",
    "shipping something small", "club leader", "hardware, mostly",
)

NO_DISPLAY_NAME_SHARE = 0.04
CUSTOM_TITLE_SHARE = 0.45


def rng_for(seed, stream="directory"):
    return random.Random(f"{seed}:{stream}")


def profiles_for(rng, members, as_of):
    shapes = {}
    for member in members:
        given = rng.choice(GIVEN_NAMES)
        family = rng.choice(FAMILY_NAMES)
        handle = f"{given}.{family[0]}" if rng.random() < 0.6 else f"{given}{rng.randrange(2, 99)}"
        tz, offset = rng.choice(TIMEZONES)
        shapes[member.user_id] = {
            "given": given,
            "family": family,
            "handle": handle,
            "display": "" if rng.random() < NO_DISPLAY_NAME_SHARE else handle,
            "pronouns": rng.choice(PRONOUN_POOL),
            "title": rng.choice(TITLES) if rng.random() < CUSTOM_TITLE_SHARE else "",
            "tz": tz,
            "tz_offset": offset,
            "hash": f"{rng.randrange(16**12):012x}",
            "updated_at": as_of - timedelta(days=rng.randrange(1, 400)),
        }
    return shapes


def member_rows(profiles, members):
    for member in members:
        shape = profiles[member.user_id]
        yield (
            member.user_id,
            shape["handle"],
            shape["display"],
            shape["title"],
            shape["pronouns"],
            f"https://avatars.{SEED_EMAIL_DOMAIN}/{shape['hash']}_192.jpg",
            shape["hash"],
            shape["tz"],
            shape["tz_offset"],
            SEED_ENTERPRISE,
            [SEED_TEAM],
            member.is_bot,
            member.deactivated_at is not None,
            member.is_admin,
            False,
            member.is_restricted,
            member.is_ultra_restricted,
            shape["updated_at"],
        )


def identity_rows(profiles, members):
    for member in members:
        shape = profiles[member.user_id]
        yield (
            member.user_id,
            f"{shape['given'].capitalize()} {shape['family'].capitalize()}",
            shape["given"].capitalize(),
            shape["family"].capitalize(),
            f"{shape['handle']}@{SEED_EMAIL_DOMAIN}",
        )

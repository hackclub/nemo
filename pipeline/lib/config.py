import argparse
import os
import sys

DATABASE = [
    "POSTGRES_HOST",
    "POSTGRES_PORT",
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
]

PIPELINE_ROLE = ["PIPELINE_DB_USER", "PIPELINE_DB_PASSWORD"]
DBT_ROLE = ["DBT_DB_USER", "DBT_DB_PASSWORD"]
RAILS_ROLE = ["RAILS_DB_USER", "RAILS_DB_PASSWORD"]

ROLES = {
    "serve": {
        "required": DATABASE + ["APP_HOST"],
        "optional": RAILS_ROLE + [
            "SECRET_KEY_BASE",
            "RAILS_MASTER_KEY",
            "HCA_ISSUER",
            "HCA_CLIENT_ID",
            "HCA_CLIENT_SECRET",
            "HCA_REDIRECT_URI",
            "NEMO_CLIENT_ID",
            "NEMO_CLIENT_SECRET",
            "SLACK_TEAM_ID",
            "FIREHOUSE_CHANNEL_ID",
            "FD_ENCRYPTION_PRIMARY_KEY",
            "FD_ENCRYPTION_DETERMINISTIC_KEY",
            "FD_ENCRYPTION_SALT",
            "INTERNAL_PROXY_URL",
            "PROXY_TOKEN_WEB",
            "PROXY_ALLOW_PLAINTEXT",
            "RAILS_MAX_THREADS",
            "WEB_CONCURRENCY",
            "RAILS_LOG_LEVEL",
            "NEMO_STREAM",
            "TLS_DOMAIN",
            "BOOTSTRAP_ADMIN_SLACK_ID",
            "TZ",
        ],
    },
    "collect": {
        "required": DATABASE + ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"],
        "optional": PIPELINE_ROLE + ["SLACK_TEAM_ID", "TZ"],
    },
    "sync": {
        "required": DATABASE + ["INTERNAL_PROXY_URL", "INTERNAL_PROXY_TOKEN"],
        "optional": PIPELINE_ROLE + DBT_ROLE + [
            "SLACK_BOT_TOKEN",
            "SLACK_TEAM_ID",
            "NIGHTLY_AT",
            "NIGHTLY_RUN_AT_START",
            "SYNC_POLL_SECONDS",
            "PROXY_ALLOW_PLAINTEXT",
            "MEMBER_HISTORY_LIMIT",
            "FIRST_REPLY_LIMIT",
            "TZ",
        ],
    },
    "transform": {
        "required": DATABASE,
        "optional": DBT_ROLE + ["TZ"],
    },
    "seed": {
        "required": DATABASE,
        "optional": PIPELINE_ROLE + DBT_ROLE + [
            "SEED_ALLOW_DB",
            "SEED_SCALE",
            "SEED_RNG",
            "SEED_HISTORY_MONTHS",
            "SEED_HOSTILE",
            "TZ",
        ],
    },
    "bot": {
        "required": DATABASE + [
            "SHROUD_BOT_TOKEN",
            "SHROUD_APP_TOKEN",
            "NEMO_BOT_TOKEN",
            "NEMO_APP_TOKEN",
            "FIREHOUSE_CHANNEL_ID",
        ],
        "optional": PIPELINE_ROLE + [
            "APP_HOST",
            "INTAKE_FILE_MAX_BYTES",
            "SLACK_TEAM_ID",
            "TZ",
        ],
    },
    "provision": {
        "required": DATABASE,
        "optional": RAILS_ROLE + PIPELINE_ROLE + DBT_ROLE + [
            "BOOTSTRAP_ADMIN_SLACK_ID",
            "TZ",
        ],
    },
}

SECRETS = ("PASSWORD", "TOKEN", "SECRET", "KEY")

DEFAULTS = {
    "POSTGRES_PORT": "5432",
    "HCA_ISSUER": "https://auth.hackclub.com",
    "RAILS_MAX_THREADS": "5",
    "WEB_CONCURRENCY": "2",
    "RAILS_LOG_LEVEL": "info",
    "NEMO_STREAM": "1",
    "TZ": "UTC",
    "NIGHTLY_AT": "03:00",
    "NIGHTLY_RUN_AT_START": "false",
    "SYNC_POLL_SECONDS": "60",
    "SEED_SCALE": "dev",
    "SEED_RNG": "1",
    "SEED_HISTORY_MONTHS": "16",
}

HEADINGS = {
    "serve": "the dashboard. the only role with a public URL",
    "collect": "the slack events listener. long running",
    "sync": "the nightly sync worker. long running",
    "transform": "dbt build. one shot",
    "seed": "synthetic data, then transform, then verify. one shot",
    "provision": "schemas, roles, grants and both migration sets. one shot",
    "bot": "shroud takes the reports, nemo works them. long running",
}

NEVER = {
    "serve": ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_TOKEN", "INTERNAL_PROXY_TOKEN"],
    "bot": [
        "SLACK_BOT_TOKEN",
        "SLACK_APP_TOKEN",
        "SLACK_TOKEN",
        "INTERNAL_PROXY_TOKEN",
    ],
}


def known(role):
    spec = ROLES[role]
    return spec["required"] + spec["optional"]


def missing(role, env=None):
    env = env if env is not None else os.environ
    return [name for name in ROLES[role]["required"] if not env.get(name)]


def unexpected(role, env=None):
    env = env if env is not None else os.environ
    allowed = set(known(role))
    named = {name for spec in ROLES.values() for name in spec["required"] + spec["optional"]}
    return sorted(name for name in named - allowed if env.get(name))


def forbidden(role, env=None):
    env = env if env is not None else os.environ
    return [name for name in NEVER.get(role, []) if env.get(name)]


def report(role, env=None):
    gone = missing(role, env)
    extra = unexpected(role, env)
    banned = forbidden(role, env)

    print(f"role {role}")
    for name in ROLES[role]["required"]:
        state = "MISSING" if name in gone else "set"
        print(f"  required  {name:28} {state}")
    if extra:
        print("  unexpected for this role, the repo does not read these here:")
        for name in extra:
            print(f"    {name}")
    if banned:
        print("  MUST NOT be set for this role:")
        for name in banned:
            print(f"    {name}")
    if gone:
        print(f"{role}: {len(gone)} required variable(s) missing: {', '.join(gone)}")
    if banned:
        print(f"{role}: {len(banned)} variable(s) present that this role must never hold")
    return 1 if gone or banned else 0


def example(role):
    spec = ROLES[role]
    lines = [
        f"# {role}: {HEADINGS[role]}",
        "# generated by `make env-examples`, do not edit by hand",
        f"NEMO_ROLE={role}",
        "",
        "# required",
    ]
    for name in spec["required"]:
        lines.append(f"{name}={DEFAULTS.get(name, '')}")
    if spec["optional"]:
        lines += ["", "# optional"]
        for name in spec["optional"]:
            lines.append(f"{name}={DEFAULTS.get(name, '')}")
    return "\n".join(lines) + "\n"


def write_examples(directory):
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for role in sorted(ROLES):
        path = directory / f"{role}.env.example"
        path.write_text(example(role))
        written.append(path)
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(prog="config")
    parser.add_argument("role", nargs="?", choices=sorted(ROLES))
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--no-env-file", action="store_true")
    args = parser.parse_args(argv)

    if args.write:
        from lib.paths import ENV_EXAMPLE_DIR

        for path in write_examples(ENV_EXAMPLE_DIR):
            print(f"wrote {path}")
        sys.exit(0)

    if not args.role:
        parser.error("a role is required unless --write is given")

    if not args.no_env_file:
        from dotenv import load_dotenv

        from lib.paths import ENV_FILE

        load_dotenv(ENV_FILE)
    sys.exit(report(args.role))


if __name__ == "__main__":
    main()

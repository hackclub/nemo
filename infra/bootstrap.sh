#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/infra/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "no $ENV_FILE. copy infra/.env.example and fill it in first" >&2
  exit 1
fi

from_env() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

for secret_file in "$ENV_FILE" "$ROOT/proxy/.env"; do
  if [ -f "$secret_file" ] && [ "$(stat -c '%a' "$secret_file")" != "600" ]; then
    chmod 600 "$secret_file"
    echo "==> tightened $secret_file to 600"
  fi
done

POSTGRES_HOST="${POSTGRES_HOST:-$(from_env POSTGRES_HOST)}"
POSTGRES_PORT="${POSTGRES_PORT:-$(from_env POSTGRES_PORT)}"
POSTGRES_USER="${POSTGRES_USER:-$(from_env POSTGRES_USER)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(from_env POSTGRES_PASSWORD)}"
POSTGRES_DB="${POSTGRES_DB:-$(from_env POSTGRES_DB)}"
PIPELINE_DB_USER="${PIPELINE_DB_USER:-$(from_env PIPELINE_DB_USER)}"
PIPELINE_DB_PASSWORD="${PIPELINE_DB_PASSWORD:-$(from_env PIPELINE_DB_PASSWORD)}"
DBT_DB_USER="${DBT_DB_USER:-$(from_env DBT_DB_USER)}"
DBT_DB_PASSWORD="${DBT_DB_PASSWORD:-$(from_env DBT_DB_PASSWORD)}"
RAILS_DB_USER="${RAILS_DB_USER:-$(from_env RAILS_DB_USER)}"
RAILS_DB_PASSWORD="${RAILS_DB_PASSWORD:-$(from_env RAILS_DB_PASSWORD)}"

case "$POSTGRES_DB" in
  *_test) echo "$POSTGRES_DB looks like a test database, use infra/test-db.sh for that" >&2; exit 1 ;;
  "") echo "POSTGRES_DB is not set" >&2; exit 1 ;;
esac

missing=()
for name in POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD \
            PIPELINE_DB_PASSWORD DBT_DB_PASSWORD RAILS_DB_PASSWORD; do
  [ -n "${!name}" ] || missing+=("$name")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "these must be set in $ENV_FILE: ${missing[*]}" >&2
  exit 1
fi

RAILS_ENV="${RAILS_ENV:-production}"
export RAILS_ENV

INTERNAL_PROXY_TOKEN="${INTERNAL_PROXY_TOKEN:-$(from_env INTERNAL_PROXY_TOKEN)}"
PROXY_TOKEN_WEB="${PROXY_TOKEN_WEB:-$(from_env PROXY_TOKEN_WEB)}"

placeholders=()
for name in POSTGRES_PASSWORD PIPELINE_DB_PASSWORD DBT_DB_PASSWORD RAILS_DB_PASSWORD \
            INTERNAL_PROXY_TOKEN PROXY_TOKEN_WEB; do
  case "${!name}" in
    change_me|change_me_to_match_the_proxy) placeholders+=("$name") ;;
  esac
done
if [ ${#placeholders[@]} -gt 0 ]; then
  if [ "$RAILS_ENV" = "production" ]; then
    echo "refusing to bootstrap production with placeholder secrets: ${placeholders[*]}" >&2
    echo "set real values in $ENV_FILE, or re-run with RAILS_ENV=development" >&2
    exit 1
  fi
  echo "warning: still placeholder: ${placeholders[*]}" >&2
fi
if [ "$RAILS_ENV" = "production" ] && [ -z "${SECRET_KEY_BASE:-}" ] && [ ! -f "$ROOT/web/config/master.key" ]; then
  echo "rails cannot boot in production without web/config/master.key or SECRET_KEY_BASE." >&2
  echo "provide one, or re-run with RAILS_ENV=development to build the schema only." >&2
  exit 1
fi

export PGPASSWORD="$POSTGRES_PASSWORD"
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
export PIPELINE_DB_USER PIPELINE_DB_PASSWORD DBT_DB_USER DBT_DB_PASSWORD
export RAILS_DB_USER RAILS_DB_PASSWORD

admin() {
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 -q "$@"
}

echo "==> target $POSTGRES_DB on $POSTGRES_HOST:$POSTGRES_PORT"

if [ -z "$(admin -d postgres -tAc "select 1 from pg_database where datname = '$POSTGRES_DB'")" ]; then
  echo "==> creating $POSTGRES_DB"
  admin -d postgres -c "create database \"$POSTGRES_DB\""
fi

echo "==> schemas, roles and grants"
admin -d "$POSTGRES_DB" -f "$ROOT/infra/postgres/init.sql"

echo "==> role passwords from $ENV_FILE"
admin -d "$POSTGRES_DB" -c "
  alter role $PIPELINE_DB_USER password '$PIPELINE_DB_PASSWORD';
  alter role $DBT_DB_USER password '$DBT_DB_PASSWORD';
  alter role $RAILS_DB_USER password '$RAILS_DB_PASSWORD';"

echo "==> app tables from the rails migrations"
(cd "$ROOT/web" && bin/rails runner 'ActiveRecord::Base.connection_pool.migration_context.migrate')

echo "==> raw schema"
(cd "$ROOT/pipeline" && PYTHONPATH=. ./.venv/bin/python -m jobs.migrate)

echo "==> the first staff row"
(cd "$ROOT/web" && bin/rails db:seed)

echo "==> analytics from dbt, so the dashboard has tables to read"
[ -f "$ROOT/dbt/profiles.yml" ] || cp "$ROOT/dbt/profiles.yml.example" "$ROOT/dbt/profiles.yml"
(cd "$ROOT/dbt" && "$ROOT/pipeline/.venv/bin/dbt" build --profiles-dir . --quiet)

echo "==> ready. what is left is not schema:"
echo "    start the proxy, then check it: curl -H \"Authorization: Bearer \$INTERNAL_PROXY_TOKEN\" \\"
echo "      http://127.0.0.1:8002/verify"
echo "    docker compose -f infra/docker-compose.yml up -d nightly-sync events-listener"
echo "    the dashboard renders empty cards until the first nightly finishes, so either"
echo "    click Run the nightly sync now, or set NIGHTLY_RUN_AT_START=true before starting"

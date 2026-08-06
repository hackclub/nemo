#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/infra/.env"
RECREATE=0

for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=1 ;;
    *) echo "usage: infra/test-db.sh [--recreate]" >&2; exit 64 ;;
  esac
done

from_env() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

POSTGRES_HOST="${POSTGRES_HOST:-$(from_env POSTGRES_HOST)}"
POSTGRES_PORT="${POSTGRES_PORT:-$(from_env POSTGRES_PORT)}"
POSTGRES_USER="${POSTGRES_USER:-$(from_env POSTGRES_USER)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(from_env POSTGRES_PASSWORD)}"
DBT_DB_USER="${DBT_DB_USER:-$(from_env DBT_DB_USER)}"
DBT_DB_PASSWORD="${DBT_DB_PASSWORD:-$(from_env DBT_DB_PASSWORD)}"
PIPELINE_DB_USER="${PIPELINE_DB_USER:-$(from_env PIPELINE_DB_USER)}"
PIPELINE_DB_PASSWORD="${PIPELINE_DB_PASSWORD:-$(from_env PIPELINE_DB_PASSWORD)}"
SOURCE_DB="${POSTGRES_DB:-$(from_env POSTGRES_DB)}"
TARGET="${POSTGRES_TEST_DB:-$(from_env POSTGRES_TEST_DB)}"
TARGET="${TARGET:-${SOURCE_DB:-mnemosyne}_test}"

case "$TARGET" in
  *_test) ;;
  *) echo "refusing to build $TARGET: a test database name must end in _test" >&2; exit 1 ;;
esac

for name in POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD DBT_DB_PASSWORD; do
  [ -n "${!name}" ] || { echo "$name is not set and $ENV_FILE does not provide it" >&2; exit 1; }
done

export PGPASSWORD="$POSTGRES_PASSWORD"
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD
export DBT_DB_USER DBT_DB_PASSWORD PIPELINE_DB_USER PIPELINE_DB_PASSWORD
export POSTGRES_DB="$TARGET" POSTGRES_TEST_DB="$TARGET"

admin() {
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 -q "$@"
}

echo "==> target $TARGET on $POSTGRES_HOST:$POSTGRES_PORT"

present="$(admin -d postgres -tAc "select 1 from pg_database where datname = '$TARGET'")"
if [ "$RECREATE" = "1" ] && [ -n "$present" ]; then
  echo "==> dropping $TARGET"
  admin -d postgres -c "drop database \"$TARGET\" with (force)"
  present=""
fi
if [ -z "$present" ]; then
  echo "==> creating $TARGET"
  admin -d postgres -c "create database \"$TARGET\""
else
  echo "==> $TARGET already exists, reapplying"
fi

echo "==> schemas, roles and grants"
admin -d "$TARGET" -f "$ROOT/infra/postgres/init.sql"

echo "==> app tables from the rails migrations"
(cd "$ROOT/web" && RAILS_ENV=test bin/rails runner 'ActiveRecord::Base.connection_pool.migration_context.migrate')

echo "==> raw schema"
(cd "$ROOT/pipeline" && PYTHONPATH=. ./.venv/bin/python -m jobs.migrate)

echo "==> seed row so the dashboard renders its headline figures"
admin -d "$TARGET" -c "
  insert into raw.team_stats_snapshot
      (ds, source, total_members_count, total_claimed_count, active_users_28d, writers_count_28d)
  values (current_date - 2, 'seed', 1000, 400, 250, 100)
  on conflict (ds) do nothing"

echo "==> analytics from dbt"
[ -f "$ROOT/dbt/profiles.yml" ] || cp "$ROOT/dbt/profiles.yml.example" "$ROOT/dbt/profiles.yml"
(cd "$ROOT/dbt" && "$ROOT/pipeline/.venv/bin/dbt" build --profiles-dir . --quiet)

echo "==> ready: cd web && bin/rails test"

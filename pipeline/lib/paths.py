from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PACKAGE_ROOT.parent

DEPLOY_DIR = REPO_ROOT / "deploy"
ENV_FILE = DEPLOY_DIR / ".env"
ENV_EXAMPLE_DIR = DEPLOY_DIR / "env"
DB_DIR = REPO_ROOT / "db"
INIT_SQL = DB_DIR / "init.sql"
PERMISSIONS_FILE = DB_DIR / "permissions.yml"
CATEGORIES_FILE = DB_DIR / "categories.yml"
ACTIONS_FILE = DB_DIR / "actions.yml"
RESOLUTIONS_FILE = DB_DIR / "resolutions.yml"
SOURCES_FILE = DB_DIR / "sources.yml"
MIGRATIONS_DIR = DB_DIR / "migrations"
WAREHOUSE_DIR = REPO_ROOT / "warehouse"
SCHEMA_DIR = PACKAGE_ROOT / "schemas"

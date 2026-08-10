from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PACKAGE_ROOT.parent

ENV_FILE = REPO_ROOT / "infra" / ".env"
WAREHOUSE_DIR = REPO_ROOT / "warehouse"
SCHEMA_DIR = REPO_ROOT / "schemas"
RAW_EVENT_SCHEMA_DIR = SCHEMA_DIR / "raw_events"
SQL_DIR = PACKAGE_ROOT / "sql"

import subprocess
import sys
from pathlib import Path

PROXY_DIR = Path(__file__).resolve().parent.parent

# Runs in a fresh subprocess per mode so sys.modules from this test process (or an
# earlier case) can never leave app/budget already imported - that would hide the
# exact ordering bug this covers: budget.py reads PROXY_BUDGET at import time, so it
# must see whatever dotenv puts in the environment, not a stale default.
SCRIPT = """
import os
from unittest.mock import patch

os.environ.pop("PROXY_BUDGET", None)

with patch("dotenv.load_dotenv",
           side_effect=lambda *a, **k: os.environ.__setitem__("PROXY_BUDGET", {mode!r})):
    import app  # noqa: F401
    import budget

assert budget.MODE == {mode!r}, f"expected {{{mode!r}}}, got {{budget.MODE!r}}"
print("ok")
"""


def run_with_dotenv_mode(mode):
    return subprocess.run(
        [sys.executable, "-c", SCRIPT.format(mode=mode)],
        cwd=PROXY_DIR, capture_output=True, text=True, timeout=30,
    )


def test_budget_mode_reflects_what_dotenv_sets():
    for mode in ("observe", "off", "on"):
        result = run_with_dotenv_mode(mode)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "ok"


def test_budget_mode_still_defaults_to_on_with_nothing_configured():
    script = """
import os
from unittest.mock import patch

os.environ.pop("PROXY_BUDGET", None)

with patch("dotenv.load_dotenv", side_effect=lambda *a, **k: None):
    import app  # noqa: F401
    import budget

assert budget.MODE == "on", budget.MODE
print("ok")
"""
    result = subprocess.run(
        [sys.executable, "-c", script], cwd=PROXY_DIR, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok"

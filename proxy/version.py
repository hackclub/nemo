import hashlib
import os
import pathlib

SOURCE = pathlib.Path(__file__).resolve().parent


def fingerprint():
    digest = hashlib.sha256()
    for path in sorted(SOURCE.glob("*.py")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()[:12]


def build():
    return {"fingerprint": fingerprint(), "rev": os.environ.get("BUILD_REV") or None}

#!/usr/bin/env python3
"""Fail if Python source or dependency manifests escape the tooling boundary."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = ROOT / "tools" / "python"
IGNORED_PARTS = {".git", ".venv", ".zig-cache", "zig-out", "__pycache__"}
MANIFEST_NAMES = {"pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "Pipfile.lock"}
violations = []

for path in ROOT.rglob("*"):
    if not path.is_file() or any(part in IGNORED_PARTS for part in path.relative_to(ROOT).parts):
        continue
    relative = path.relative_to(ROOT)
    if path.suffix == ".py" and not path.is_relative_to(ALLOWED):
        violations.append(f"Python source outside tools/python/: {relative}")
    if (path.name in MANIFEST_NAMES or
            (path.name.startswith("requirements") and path.suffix == ".txt")) and not path.is_relative_to(ALLOWED):
        violations.append(f"Python dependency manifest outside tools/python/: {relative}")

if violations:
    print("\n".join(violations), file=sys.stderr)
    raise SystemExit(1)

print("OK: Python sources and dependency manifests are isolated under tools/python/.")

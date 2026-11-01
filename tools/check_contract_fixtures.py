#!/usr/bin/env python3
"""Check duplicated approved fixtures without depending on Zig or third-party Python."""
import json
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    for filename in ("EmptyGame.proj", "presets.zon"):
        documented = (root / "docs" / "examples" / filename).read_bytes()
        packaged = (root / "shared" / "fixtures" / filename).read_bytes()
        if documented != packaged:
            raise SystemExit(f"Fixture divergiu do contrato aprovado: {filename}")
    schema = json.loads((root / "docs/schemas/project-v1.schema.json").read_text(encoding="utf-8"))
    project = json.loads((root / "shared/fixtures/EmptyGame.proj").read_text(encoding="utf-8"))
    if project["schema_version"] != schema["properties"]["schema_version"]["const"]:
        raise SystemExit("Versão do exemplo divergiu do schema")
    print("OK: fixtures empacotadas idênticas aos exemplos aprovados; versão coerente.")


if __name__ == "__main__":
    main()

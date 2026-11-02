#!/usr/bin/env python3
"""Check duplicated approved fixtures without depending on Zig or third-party Python."""
import hashlib
import json
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    for filename in ("EmptyGame.proj", "EmptyGameV2.proj", "presets.zon"):
        documented = (root / "docs" / "examples" / filename).read_bytes()
        packaged = (root / "shared" / "fixtures" / filename).read_bytes()
        if documented != packaged:
            raise SystemExit(f"Fixture divergiu do contrato aprovado: {filename}")
    schema = json.loads((root / "docs/schemas/project-v1.schema.json").read_text(encoding="utf-8"))
    project = json.loads((root / "shared/fixtures/EmptyGame.proj").read_text(encoding="utf-8"))
    if project["schema_version"] != schema["properties"]["schema_version"]["const"]:
        raise SystemExit("Versão do exemplo divergiu do schema")
    v2_schema = json.loads((root / "docs/schemas/project-v2.schema.json").read_text(encoding="utf-8"))
    v2_project = json.loads((root / "shared/fixtures/EmptyGameV2.proj").read_text(encoding="utf-8"))
    if v2_project["schema_version"] != v2_schema["properties"]["schema_version"]["const"]:
        raise SystemExit("Versão do exemplo v2 divergiu do schema")
    if v2_schema["properties"]["engine"]["properties"]["graphics_backend"]["enum"] != ["vulkan", "opengl", "d3d11", "d3d12"]:
        raise SystemExit("Backends v2 divergiram do ADR-003")
    manifest = json.loads((root / "shared/fixtures/distribution.json").read_text(encoding="utf-8"))
    table = (root / "shared/fixtures/presets.zon").read_bytes()
    if hashlib.sha256(table).hexdigest() != manifest["presets_sha256"]:
        raise SystemExit("SHA-256 da tabela divergiu do manifesto empacotado")
    print("OK: fixtures empacotadas idênticas aos exemplos aprovados; versão e SHA-256 coerentes.")


if __name__ == "__main__":
    main()

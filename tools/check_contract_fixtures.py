#!/usr/bin/env python3
"""Check duplicated approved fixtures without depending on Zig or third-party Python."""
import hashlib
import json
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    for filename in ("EmptyGame.proj", "EmptyGameV2.proj", "EmptyGameV3.proj", "presets.zon"):
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
    v3_schema = json.loads((root / "docs/schemas/project-v3.schema.json").read_text(encoding="utf-8"))
    v3_project = json.loads((root / "shared/fixtures/EmptyGameV3.proj").read_text(encoding="utf-8"))
    if v3_project["schema_version"] != v3_schema["properties"]["schema_version"]["const"]:
        raise SystemExit("Versão do exemplo v3 divergiu do schema")
    profiles = v3_schema["properties"]["renderer"]["properties"]["profile"]["enum"]
    if v3_schema["properties"]["renderer"]["required"][0] != "profile" or profiles != ["advanced", "standard", "lite"]:
        raise SystemExit("Renderer profile v3 divergiu do contrato aprovado")
    if v3_project["renderer"].get("profile") not in profiles:
        raise SystemExit("Renderer profile da fixture v3 não pertence ao schema")
    if v3_schema["properties"]["engine"]["properties"]["graphics_backend"]["enum"] != ["vulkan", "opengl", "d3d11", "d3d12"]:
        raise SystemExit("Backends v3 divergiram do ADR-003")
    manifest = json.loads((root / "shared/fixtures/distribution.template.json").read_text(encoding="utf-8"))
    table = (root / "shared/fixtures/presets.zon").read_bytes()
    if hashlib.sha256(table).hexdigest() != manifest["presets_sha256"]:
        raise SystemExit("SHA-256 da tabela divergiu do manifesto empacotado")
    print("OK: fixtures V1/V2/V3 idênticas aos exemplos aprovados; versões, Renderer profile e SHA-256 coerentes.")


if __name__ == "__main__":
    main()

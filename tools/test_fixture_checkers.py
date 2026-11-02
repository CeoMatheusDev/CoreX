#!/usr/bin/env python3
"""Compare the old and new fixture checkers on isolated, controlled inputs.

This migration test intentionally retains Python while the reference checker is
kept. The Zig CLI is passed as an absolute or relative executable path; neither
checker is allowed to mutate the repository fixtures.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PATHS = (
    "docs/examples/EmptyGame.proj",
    "shared/fixtures/EmptyGame.proj",
    "docs/examples/EmptyGameV2.proj",
    "shared/fixtures/EmptyGameV2.proj",
    "docs/examples/presets.zon",
    "shared/fixtures/presets.zon",
    "docs/schemas/project-v1.schema.json",
    "docs/schemas/project-v2.schema.json",
    "shared/fixtures/distribution.json",
)
CHECKER = None


class FixtureCheckers(unittest.TestCase):
    def fresh(self):
        temporary = tempfile.TemporaryDirectory(prefix="CoreX ação ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for name in (*PATHS, "tools/check_contract_fixtures.py"):
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, destination)
        (root / "unrelated cwd").mkdir()
        return root

    def compare(self, root, python_ok, zig_ok, zig_error=None):
        cwd = root / "unrelated cwd"
        python = subprocess.run(
            [sys.executable, str(root / "tools/check_contract_fixtures.py")],
            cwd=cwd, capture_output=True, timeout=20,
        )
        zig = subprocess.run(
            [str(CHECKER), "--root", str(root)], cwd=cwd,
            capture_output=True, timeout=20,
        )
        self.assertEqual(python.returncode, 0 if python_ok else 1, python.stderr)
        self.assertEqual(zig.returncode, 0 if zig_ok else 1, zig.stderr)
        if zig_error:
            self.assertIn(zig_error.encode(), zig.stderr)
        if zig_ok:
            self.assertIn(b"OK:", zig.stdout)

    @staticmethod
    def put_json(root, name, value):
        (root / name).write_text(json.dumps(value), encoding="utf-8")

    @staticmethod
    def pair(root, example, fixture, data):
        (root / example).write_bytes(data)
        (root / fixture).write_bytes(data)

    def test_valid_and_default_cwd(self):
        root = self.fresh()
        self.compare(root, True, True)
        result = subprocess.run([str(CHECKER)], cwd=root, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"OK:", result.stdout)

    def test_each_documented_pair_mismatch(self):
        for name, error in (
            (PATHS[0], "V1FixtureMismatch"),
            (PATHS[2], "V2FixtureMismatch"),
            (PATHS[4], "PresetsFixtureMismatch"),
        ):
            with self.subTest(name=name):
                root = self.fresh()
                (root / name).write_bytes(b"different")
                self.compare(root, False, False, error)

    def test_each_input_is_required(self):
        for name in PATHS:
            with self.subTest(name=name):
                root = self.fresh()
                (root / name).unlink()
                self.compare(root, False, False, "FileNotFound")

    def test_invalid_json_in_every_parsed_file(self):
        for name in (PATHS[1], PATHS[3], PATHS[6], PATHS[7], PATHS[8]):
            with self.subTest(name=name):
                root = self.fresh()
                if name == PATHS[1]:
                    self.pair(root, PATHS[0], PATHS[1], b"{")
                elif name == PATHS[3]:
                    self.pair(root, PATHS[2], PATHS[3], b"{")
                else:
                    (root / name).write_bytes(b"{")
                self.compare(root, False, False, "UnexpectedEndOfInput")

    def test_versions_changed_independently(self):
        for version, schema_name, example, fixture in (
            (1, PATHS[6], PATHS[0], PATHS[1]),
            (2, PATHS[7], PATHS[2], PATHS[3]),
        ):
            for change_schema in (False, True):
                with self.subTest(version=version, schema=change_schema):
                    root = self.fresh()
                    if change_schema:
                        schema = json.loads((root / schema_name).read_text(encoding="utf-8"))
                        schema["properties"]["schema_version"]["const"] = 99
                        self.put_json(root, schema_name, schema)
                    else:
                        project = json.loads((root / fixture).read_text(encoding="utf-8"))
                        project["schema_version"] = 99
                        self.pair(root, example, fixture, json.dumps(project).encode())
                    self.compare(root, False, False, "SchemaVersionMismatch")

    def test_backends_and_hash(self):
        for values in (
            ["opengl", "vulkan", "d3d11", "d3d12"],
            ["vulkan", "opengl", "d3d11"],
            ["vulkan", "opengl", "d3d11", "d3d12", "metal"],
            ["vulkan", "opengl", "d3d11", 12],
        ):
            with self.subTest(backends=values):
                root = self.fresh()
                schema = json.loads((root / PATHS[7]).read_text(encoding="utf-8"))
                schema["properties"]["engine"]["properties"]["graphics_backend"]["enum"] = values
                self.put_json(root, PATHS[7], schema)
                self.compare(root, False, False, "BackendMismatch")
        for values in (None, "vulkan"):
            with self.subTest(non_array_backends=values):
                root = self.fresh()
                schema = json.loads((root / PATHS[7]).read_text(encoding="utf-8"))
                schema["properties"]["engine"]["properties"]["graphics_backend"]["enum"] = values
                self.put_json(root, PATHS[7], schema)
                self.compare(root, False, False, "InvalidContractShape")
        root = self.fresh()
        self.pair(root, PATHS[4], PATHS[5], b"modified presets")
        self.compare(root, False, False, "PresetsHashMismatch")

    def test_missing_or_wrong_shape_fields(self):
        for name, field in ((PATHS[6], "properties"), (PATHS[7], "properties"),
                            (PATHS[8], "presets_sha256")):
            with self.subTest(name=name):
                root = self.fresh()
                value = json.loads((root / name).read_text(encoding="utf-8"))
                del value[field]
                self.put_json(root, name, value)
                self.compare(root, False, False, "InvalidContractShape")
        root = self.fresh()
        self.put_json(root, PATHS[8], {"presets_sha256": 123})
        self.compare(root, False, False, "InvalidContractShape")

    def test_intentional_stricter_duplicate_json_keys(self):
        root = self.fresh()
        original = (root / PATHS[1]).read_bytes()
        self.assertTrue(original.startswith(b"{"))
        self.pair(root, PATHS[0], PATHS[1], b'{"schema_version":1,' + original[1:])
        self.compare(root, True, False, "DuplicateField")

    def test_intentional_exact_schema_version_policy(self):
        for project_version, schema_version, error in (
            (3, 3, "SchemaVersionMismatch"),
            (True, 1, "InvalidContractShape"),
            (1.0, 1, "InvalidContractShape"),
        ):
            with self.subTest(version=project_version):
                root = self.fresh()
                project = json.loads((root / PATHS[1]).read_text(encoding="utf-8"))
                project["schema_version"] = project_version
                self.pair(root, PATHS[0], PATHS[1], json.dumps(project).encode())
                schema = json.loads((root / PATHS[6]).read_text(encoding="utf-8"))
                schema["properties"]["schema_version"]["const"] = schema_version
                self.put_json(root, PATHS[6], schema)
                self.compare(root, True, False, error)

    def test_intentional_file_size_limit_and_boundary(self):
        root = self.fresh()
        original = (root / PATHS[1]).read_bytes()
        boundary = original + b" " * (4 * 1024 * 1024 - len(original))
        self.pair(root, PATHS[0], PATHS[1], boundary)
        self.compare(root, True, True)
        self.pair(root, PATHS[0], PATHS[1], boundary + b" ")
        self.compare(root, True, False, "FileTooLarge")

    def test_zig_cli_arguments(self):
        root = self.fresh()
        for args, expected in ((["--help"], 0), (["--root"], 1),
                               (["--root", ""], 1), (["--help", "extra"], 1),
                               (["--unknown"], 1), (["--root", str(root / "missing")], 1)):
            with self.subTest(args=args):
                result = subprocess.run([str(CHECKER), *args], cwd=root, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, expected, result.stderr)
                if args == ["--help"]:
                    self.assertIn(b"Usage:", result.stdout)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python tools/test_fixture_checkers.py PATH_TO_ZIG_CHECKER")
    CHECKER = Path(sys.argv.pop()).resolve(strict=True)
    unittest.main(verbosity=2)

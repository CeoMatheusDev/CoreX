#!/usr/bin/env python3
"""Offline tests for the legacy dependency archive verifier."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

import prepare_legacy_deps as prepare
from prepare_legacy_deps import extract_verified


def archive(name: str, kind: bytes = tarfile.REGTYPE) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo(name)
        info.type = kind
        data = b"contents" if kind == tarfile.REGTYPE else b""
        info.size = len(data)
        if kind == tarfile.SYMTYPE:
            info.linkname = "/tmp/escape"
        tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class ArchiveVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dest = Path(self.tmp.name)

    def extract(self, data, digest=None):
        extract_verified(data, digest or hashlib.sha256(data).hexdigest(), "pkg", self.dest)

    def test_external_zig_is_used_for_version_and_fetch(self):
        wheel = archive("pkg/sub/file")
        digest = hashlib.sha256(wheel).hexdigest()
        archives = self.dest / "archives"
        archives.mkdir()
        (archives / "sample.tar.gz").write_bytes(wheel)
        (self.dest / "build.zig.zon").write_text('.hash = "sample-hash"', encoding="utf-8")
        zig = self.dest / "zig executable"
        zig.touch()
        packages = (("sample", "v1", "pkg", digest, "sample-hash"),)
        calls = []

        def fake_check_output(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[-1] == "version":
                return "0.17.0\n"
            self.assertEqual(argv[0], str(zig))
            self.assertEqual(argv[1], "fetch")
            self.assertTrue(Path(argv[2], "sub/file").is_file())
            self.assertEqual(kwargs["cwd"], self.dest)
            return "sample-hash\n"

        with mock.patch.object(prepare, "ROOT", self.dest), \
             mock.patch.object(prepare, "PACKAGES", packages), \
             mock.patch.object(prepare.subprocess, "check_output", side_effect=fake_check_output), \
             mock.patch.object(prepare.sys, "argv", ["prepare_legacy_deps.py", "--archive-dir", str(archives), "--zig", str(zig)]):
            prepare.main()
        self.assertEqual(calls[0][0], [str(zig), "version"])
        self.assertEqual(len(calls), 2)

    def test_external_zig_wrong_version_fails_before_fetch(self):
        zig = self.dest / "zig"
        zig.touch()
        with mock.patch.object(prepare.subprocess, "check_output", return_value="0.16.0\n") as output, \
             mock.patch.object(prepare.sys, "argv", ["prepare_legacy_deps.py", "--zig", str(zig)]):
            with self.assertRaisesRegex(SystemExit, "Expected Zig 0.17.0"):
                prepare.main()
        output.assert_called_once_with([str(zig), "version"], text=True)

    def test_valid_archive(self):
        self.extract(archive("pkg/sub/file"))
        self.assertEqual((self.dest / "sub/file").read_bytes(), b"contents")

    def test_mismatch_rejected_before_extraction(self):
        with self.assertRaises(ValueError):
            self.extract(archive("pkg/file"), "0" * 64)
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_paths_and_links_rejected(self):
        for name, kind in [("pkg/../escape", tarfile.REGTYPE),
                           ("/pkg/file", tarfile.REGTYPE),
                           ("other/file", tarfile.REGTYPE),
                           ("pkg/link", tarfile.SYMTYPE)]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.extract(archive(name, kind))


if __name__ == "__main__":
    unittest.main()

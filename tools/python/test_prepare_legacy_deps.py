#!/usr/bin/env python3
"""Offline tests for the legacy dependency archive verifier."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

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

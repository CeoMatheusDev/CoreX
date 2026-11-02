#!/usr/bin/env python3
"""Prime the Zig 0.17 package cache from verified upstream release archives.

This is a development/build helper; it is not imported by Editor or Runtime.

Work around the extra wrapper directory introduced when this Zig version caches
GitHub tarballs directly. No dependency versions or Zig package hashes change.
"""
import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = (
    ("zigway", "v0.1.0-alpha.4", "Zigway-0.1.0-alpha.4",
     "07a4615916f50b14eac3241e763c499cf64c021f61a147dbd5ceb2ec02f723e0",
     "zigway-0.1.0-alpha.4-J1VBH_6UDAB_K4K2qoaGf3VkKqRxg2T5tgKqJzWQsJ_P"),
    ("zyntra_ui", "v1.44.1", "ZyntraUI-1.44.1",
     "cd6a21c0821d8c1e3b525e15233fe41e9acc429c421122b19f2e160ebf714bee",
     "zyntra_ui-1.44.1-sgzbJL9GLABJOlz_u9WkQYOw3lVB2d7TJBbbXSHudeYN"),
)
MAX_ARCHIVE = 16 * 1024 * 1024
MAX_EXTRACTED = 64 * 1024 * 1024


def extract_verified(data: bytes, digest: str, prefix: str, destination: Path) -> None:
    if len(data) > MAX_ARCHIVE or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"{prefix}: archive SHA-256 mismatch or size limit exceeded")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = archive.getmembers()
        if sum(m.size for m in members) > MAX_EXTRACTED:
            raise ValueError(f"{prefix}: extracted size limit exceeded")
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or not path.parts or path.parts[0] != prefix
                    or ".." in path.parts or not (member.isdir() or member.isfile())):
                raise ValueError(f"{prefix}: unsafe archive member {member.name!r}")
            relative = path.parts[1:]
            if not relative:
                if not member.isdir():
                    raise ValueError(f"{prefix}: invalid archive root")
                continue
            output = destination.joinpath(*relative)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, output.open("xb") as target:
                    target.write(source.read())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-dir", type=Path, help="use local zigway.tar.gz and zyntra_ui.tar.gz instead of downloading")
    args = parser.parse_args()
    zig = [sys.executable, "-m", "ziglang"]
    version = subprocess.check_output([*zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise SystemExit(f"Expected Zig 0.17.0, got {version}")
    manifest = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="corex-deps-") as temporary:
        for name, tag, prefix, digest, expected in PACKAGES:
            if f'.hash = "{expected}"' not in manifest:
                raise ValueError(f"{name}: expected hash is not in build.zig.zon; update pins deliberately")
            if args.archive_dir:
                data = (args.archive_dir / f"{name}.tar.gz").read_bytes()
            else:
                repo = "Zigway" if name == "zigway" else "ZyntraUI"
                url = f"https://codeload.github.com/CeoMatheusDev/{repo}/tar.gz/refs/tags/{tag}"
                with urllib.request.urlopen(url, timeout=60) as response:
                    data = response.read(MAX_ARCHIVE + 1)
            directory = Path(temporary) / name
            directory.mkdir()
            extract_verified(data, digest, prefix, directory)
            actual = subprocess.check_output([*zig, "fetch", str(directory)], cwd=ROOT, text=True).strip()
            if actual != expected:
                raise ValueError(f"{name}: Zig package hash mismatch: {actual} != {expected}")
            print(f"{name}: verified {actual}", flush=True)


if __name__ == "__main__":
    main()

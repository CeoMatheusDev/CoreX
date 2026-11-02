#!/usr/bin/env python3
"""Verify unsupported application targets fail for the intended policy reason.

Run with the Python interpreter that has the pinned ziglang toolchain installed.
This never executes a cross-compiled binary and does not claim native Windows.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    for package in ("editor", "runtime"):
        for target in ("aarch64-macos", "x86_64-freebsd", "wasm32-wasi"):
            result = subprocess.run(
                [sys.executable, "-m", "ziglang", "build", "check", f"-Dtarget={target}", "-j2"],
                cwd=ROOT / package, capture_output=True, timeout=120,
            )
            if result.returncode == 0 or b"Unsupported application target:" not in result.stderr:
                raise SystemExit(f"wrong target rejection: {package}/{target}: {result.stderr!r}")
            print(f"OK: {package} rejects {target} explicitly")


if __name__ == "__main__":
    main()

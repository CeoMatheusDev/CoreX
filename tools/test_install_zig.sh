#!/bin/sh
# Offline regression tests; optionally pass the actual pinned wheel to exercise
# a successful install too. No files outside a private temporary directory.
set -eu
if [ "$#" -gt 1 ]; then echo 'usage: sh tools/test_install_zig.sh [LOCAL_WHEEL]' >&2; exit 2; fi
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-zig-install.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
installer="$repo/tools/install_zig.sh"
printf 'not a wheel' > "$tmp/bad.whl"
if sh "$installer" "$tmp/bad-install" "$tmp/bad.whl" > "$tmp/out" 2>&1; then
    echo 'installer accepted an unverified wheel' >&2; exit 1
fi
grep -q 'SHA-256 mismatch' "$tmp/out"
if [ -d "$tmp/bad-install" ] || [ -L "$tmp/bad-install" ]; then echo 'failed install was not cleaned up' >&2; exit 1; fi
# A sparse oversized file exercises the limit without consuming 105 MB.
dd if=/dev/zero of="$tmp/oversized.whl" bs=1 count=0 seek=105000001 2>/dev/null
if sh "$installer" "$tmp/large-install" "$tmp/oversized.whl" > "$tmp/out" 2>&1; then
    echo 'installer accepted an oversized wheel' >&2; exit 1
fi
grep -q 'exceeds size limit' "$tmp/out"
if [ -d "$tmp/large-install" ] || [ -L "$tmp/large-install" ]; then echo 'oversized install was not cleaned up' >&2; exit 1; fi
mkdir "$tmp/existing"
printf 'keep me' > "$tmp/existing/marker"
if sh "$installer" "$tmp/existing" "$tmp/bad.whl" > "$tmp/out" 2>&1; then
    echo 'installer overwrote an existing directory' >&2; exit 1
fi
test "$(cat "$tmp/existing/marker")" = 'keep me'
ln -s "$tmp/existing" "$tmp/link"
if sh "$installer" "$tmp/link" "$tmp/bad.whl" > "$tmp/out" 2>&1; then
    echo 'installer accepted a symlink destination' >&2; exit 1
fi
test "$(cat "$tmp/existing/marker")" = 'keep me'
mkdir "$tmp/fake-bin"
printf '#!/bin/sh\nprintf "UnsupportedOS\\n"\n' > "$tmp/fake-bin/uname"
chmod +x "$tmp/fake-bin/uname"
if PATH="$tmp/fake-bin:$PATH" sh "$installer" "$tmp/unsupported" "$tmp/bad.whl" > "$tmp/out" 2>&1; then
    echo 'installer accepted an unsupported host' >&2; exit 1
fi
grep -q 'unsupported host' "$tmp/out"
if [ -d "$tmp/unsupported" ] || [ -L "$tmp/unsupported" ]; then echo 'unsupported host created an install directory' >&2; exit 1; fi
if [ "$#" -eq 1 ]; then
    sh "$installer" "$tmp/install ação" "$1"
    test "$("$tmp/install ação/ziglang/zig" version)" = '0.17.0'
    test -f "$tmp/install ação/ziglang/lib/std/std.zig"
    test -f "$tmp/install ação/ziglang/LICENSE"
    test ! -f "$tmp/install ação/ziglang/__main__.py"
    case "$(uname -m)" in x86_64) other=aarch64 ;; aarch64|arm64) other=x86_64 ;; *) other= ;; esac
    if [ -n "$other" ]; then
        printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo %s ;; esac\n' "$other" > "$tmp/fake-bin/uname"
        if PATH="$tmp/fake-bin:$PATH" sh "$installer" "$tmp/wrong-architecture" "$1" > "$tmp/out" 2>&1; then
            echo 'installer accepted a wheel for a different architecture' >&2; exit 1
        fi
        grep -q 'SHA-256 mismatch' "$tmp/out"
        if [ -d "$tmp/wrong-architecture" ] || [ -L "$tmp/wrong-architecture" ]; then
            echo 'wrong-architecture install was not cleaned up' >&2; exit 1
        fi
    fi
fi
echo 'OK: Zig bootstrap verifies pinned bytes and refuses unsafe installations'

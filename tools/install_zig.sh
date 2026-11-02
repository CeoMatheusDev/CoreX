#!/bin/sh
# Install the same pinned ziglang wheel previously used by pip, without Python.
# This is a Linux host bootstrap, not a claim that a Windows binary exists.
# Usage: sh tools/install_zig.sh ABSOLUTE_NEW_DIRECTORY [LOCAL_WHEEL]
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo 'usage: sh tools/install_zig.sh ABSOLUTE_NEW_DIRECTORY [LOCAL_WHEEL]' >&2
    exit 2
fi
dest=$1
case "$dest" in /*) ;; *) echo 'destination must be absolute' >&2; exit 2 ;; esac
case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        url='https://files.pythonhosted.org/packages/fe/6f/e1c380fe61db36cb464d5d4d18c557338812500986885373e2550d4ebf6b/ziglang-0.17.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.musllinux_1_1_x86_64.whl'
        expected='97079827064a7492cce5541ceb438ae8003ce1e54e399676da2d62fb7a5dc08b'
        ;;
    Linux:aarch64|Linux:arm64)
        url='https://files.pythonhosted.org/packages/02/21/abee2f0524f54fe3e8783748b9df79bb07d4b955e6b465677d1cfbda335c/ziglang-0.17.0-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64.whl'
        expected='d2804f94f54f7fcf8169f4b212a619ad688a4e2e6592e976f0cf2e58e2cd8af3'
        ;;
    *) echo 'unsupported host: this bootstrap is for Linux x86_64/aarch64 only' >&2; exit 2 ;;
esac
# The destination must not exist, including symlinks. mkdir is atomic; do not
# overwrite a previous installation or extract into an attacker-chosen tree.
umask 077
if ! mkdir "$dest"; then
    echo "cannot create new installation directory: $dest" >&2
    exit 1
fi
cleanup() { rm -rf "$dest"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
archive="$dest/archive.whl"
max_bytes=105000000
if [ "$#" -eq 2 ]; then
    if [ ! -f "$2" ]; then echo 'local wheel must be a regular file' >&2; exit 1; fi
    size=$(wc -c < "$2")
    if [ "$size" -gt "$max_bytes" ]; then echo 'wheel exceeds size limit' >&2; exit 1; fi
    # Bound the copy too, even if the input grows after the size check.
    dd if="$2" of="$archive" bs=1048576 count=101 2>/dev/null
else
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time 300 --max-filesize "$max_bytes" --output "$archive" "$url"
fi
size=$(wc -c < "$archive")
if [ "$size" -gt "$max_bytes" ]; then echo 'wheel exceeds size limit' >&2; exit 1; fi
actual=$(sha256sum < "$archive")
actual=${actual%% *}
if [ "$actual" != "$expected" ]; then
    echo 'wheel SHA-256 mismatch; no archive content was extracted' >&2
    exit 1
fi
# Extraction is permitted only for these exact, repository-pinned wheel bytes.
# Do not generalize this to arbitrary archives. Python package files are omitted.
unzip -q "$archive" 'ziglang/zig' 'ziglang/lib/*' 'ziglang/LICENSE' -d "$dest"
test -f "$dest/ziglang/lib/std/std.zig"
test -f "$dest/ziglang/LICENSE"
chmod u+x "$dest/ziglang/zig"
version=$("$dest/ziglang/zig" version)
if [ "$version" != '0.17.0' ]; then echo "unexpected Zig version: $version" >&2; exit 1; fi
rm "$archive"
trap - 0 HUP INT TERM
printf 'Installed Zig %s at %s/ziglang/zig\n' "$version" "$dest"

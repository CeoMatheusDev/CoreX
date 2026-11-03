#!/bin/sh
# Verify the temporary allowlist guard in an isolated Git index.
set -eu
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-python-guard.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$tmp/tools"
cp "$repo/tools/check_python_inventory.sh" "$repo/tools/python-migration-allowlist.txt" "$tmp/tools/"
while IFS= read -r path; do
    mkdir -p "$tmp/$(dirname "$path")"
    : > "$tmp/$path"
done < "$tmp/tools/python-migration-allowlist.txt"
git -C "$tmp" init -q
git -C "$tmp" add tools
sh "$tmp/tools/check_python_inventory.sh"
for name in new.py other.pyw; do
    : > "$tmp/tools/$name"
    git -C "$tmp" add "tools/$name"
    if sh "$tmp/tools/check_python_inventory.sh" > "$tmp/out" 2>&1; then
        echo "inventory guard accepted unlisted $name" >&2
        exit 1
    fi
    git -C "$tmp" rm --cached -q "tools/$name"
    rm "$tmp/tools/$name"
done
git -C "$tmp" rm --cached -q tools/ci_capture.py
if sh "$tmp/tools/check_python_inventory.sh" > "$tmp/out" 2>&1; then
    echo 'inventory guard accepted a stale allowlist entry' >&2
    exit 1
fi
echo 'OK: inventory guard rejects unlisted Python files and stale entries'

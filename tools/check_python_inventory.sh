#!/bin/sh
# Transitional CI guard: tracked Python files must be explicitly inventoried.
# Remove entries as implementations and their regression coverage are migrated.
set -eu
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-python-inventory.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
cd "$repo"
git ls-files -- '*.py' '*.pyw' > "$tmp/tracked"
LC_ALL=C sort "$tmp/tracked" > "$tmp/actual"
LC_ALL=C sort tools/python-migration-allowlist.txt > "$tmp/expected"
if ! diff -u "$tmp/expected" "$tmp/actual"; then
    echo 'Python inventory changed: review the migration plan and update the allowlist deliberately.' >&2
    exit 1
fi
echo 'OK: tracked Python files match the transitional migration inventory'

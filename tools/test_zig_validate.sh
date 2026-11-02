#!/bin/sh
# Exercise the Zig build entry point on an isolated, mutable fixture tree.
# Usage: sh tools/test_zig_validate.sh /absolute/path/to/zig
set -eu
if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then
    echo 'usage: sh tools/test_zig_validate.sh /absolute/path/to/zig' >&2
    exit 2
fi
case "$1" in /*) zig=$1 ;; *) echo 'Zig path must be absolute' >&2; exit 2 ;; esac
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-validate.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
root="$tmp/Projeto ação"
mkdir -p "$root/docs" "$root/shared"
cp -R "$repo/docs/examples" "$repo/docs/schemas" "$root/docs/"
cp -R "$repo/shared/fixtures" "$root/shared/"
cd "$repo/tools/zig"
"$zig" build validate-fixtures -Drepository-root="$root" --summary all
"$zig" build test-fixture-cli -Drepository-root="$root" --summary all
# A prior success must not be cached: mutate data, expect failure, then restore.
printf 'changed\n' >> "$root/shared/fixtures/EmptyGame.proj"
if "$zig" build validate-fixtures -Drepository-root="$root" --summary all >"$tmp/out" 2>"$tmp/err"; then
    echo 'invalid fixture unexpectedly passed' >&2
    exit 1
fi
if ! grep -q V1FixtureMismatch "$tmp/err"; then
    cat "$tmp/err" >&2
    echo 'fixture failed for an unexpected reason' >&2
    exit 1
fi
if "$zig" build test-fixture-cli -Drepository-root="$root" --summary all >"$tmp/out" 2>"$tmp/err"; then
    echo 'CLI tests reused a stale success after fixture corruption' >&2
    exit 1
fi
if ! grep -q 'test_fixture_cli.test.valid actual inputs' "$tmp/err" || ! grep -q V1FixtureMismatch "$tmp/err"; then
    cat "$tmp/err" >&2
    echo 'CLI test failed for an unexpected reason' >&2
    exit 1
fi
if "$zig" build validate-fixtures -Dtarget=x86_64-windows-gnu -Drepository-root="$root" >"$tmp/out" 2>"$tmp/err"; then
    echo 'cross-target native validation unexpectedly passed' >&2
    exit 1
fi
if ! grep -q 'native-only' "$tmp/err"; then
    cat "$tmp/err" >&2
    echo 'cross-target validation failed for an unexpected reason' >&2
    exit 1
fi
if "$zig" build test-fixture-cli -Dtarget=x86_64-windows-gnu -Drepository-root="$root" >"$tmp/out" 2>"$tmp/err"; then
    echo 'cross-target CLI tests unexpectedly ran' >&2
    exit 1
fi
if ! grep -q 'native-only' "$tmp/err"; then
    cat "$tmp/err" >&2
    echo 'cross-target CLI tests failed for an unexpected reason' >&2
    exit 1
fi
cp "$root/docs/examples/EmptyGame.proj" "$root/shared/fixtures/EmptyGame.proj"
"$zig" build validate-fixtures -Drepository-root="$root" --summary all
"$zig" build test-fixture-cli -Drepository-root="$root" --summary all
echo 'OK: Zig validation runs on every invocation and rejects changed fixtures'

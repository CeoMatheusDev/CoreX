#!/bin/sh
# POSIX black-box smoke tests of the Linux Zig capture CLI. No Python needed.
set -eu
if [ "$#" -ne 1 ]; then echo 'usage: sh tools/test_ci_capture_smoke.sh /absolute/path/to/corex-ci-capture' >&2; exit 2; fi
case "$1" in /*) [ -x "$1" ] || exit 2 ;; *) exit 2 ;; esac
capture=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-capture-smoke.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
mkdir "$tmp/empty-path"
ln -s "$capture" "$tmp/captura ação"
# Start a shell by absolute path with an empty PATH: the wrapper itself must
# not invoke Python, PATH search, or another helper for this operation.
PATH="$tmp/empty-path" GITHUB_ACTIONS=true "$tmp/captura ação" /bin/sh -c 'printf "ok"' > "$tmp/out" 2> "$tmp/err"
test "$(cat "$tmp/out")" = ok
test ! -s "$tmp/err"
set +e
PATH="$tmp/empty-path" GITHUB_ACTIONS=true "$tmp/captura ação" /bin/sh -c 'printf "alpha%%\r\nbeta"; exit 7' > "$tmp/out" 2> "$tmp/err"
status=$?
set -e
test "$status" -eq 7
grep -Fq '::error title=CI command failed::exit 7: alpha%25%0D%0Abeta' "$tmp/out"
test ! -s "$tmp/err"
set +e
GITHUB_ACTIONS=false "$capture" /bin/sh -c 'kill -TERM $$' > "$tmp/out" 2> "$tmp/err"
status=$?
set -e
test "$status" -eq 143
if grep -Fq '::error' "$tmp/out"; then echo 'unexpected annotation outside Actions' >&2; exit 1; fi
set +e
"$capture" > "$tmp/out" 2> "$tmp/err"
status=$?
set -e
test "$status" -eq 2
grep -qi usage "$tmp/err"
set +e
"$capture" "$tmp/not-an-executable" > "$tmp/out" 2> "$tmp/err"
status=$?
set -e
test "$status" -eq 127
grep -q 'could not launch CI command' "$tmp/err"
echo 'OK: Zig CI capture forwards output, status, signals and annotations without Python'

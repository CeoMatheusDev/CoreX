#!/bin/sh
# Prepare the two pinned legacy packages using Zig and POSIX shell, no Python.
# The destination is Zig's package cache. Temporary files are always private.
set -eu
usage() { echo 'usage: sh tools/prepare_legacy_deps.sh --zig /absolute/path/to/zig [--archive-dir DIRECTORY]' >&2; exit 2; }
zig=
archives=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --zig) [ "$#" -ge 2 ] && [ -z "$zig" ] && [ -n "$2" ] || usage; zig=$2; shift 2 ;;
        --archive-dir) [ "$#" -ge 2 ] && [ -z "$archives" ] && [ -n "$2" ] || usage; archives=$2; shift 2 ;;
        *) usage ;;
    esac
done
case "$zig" in /*) [ -x "$zig" ] || usage ;; *) usage ;; esac
if [ -n "$archives" ]; then
    archives=$(CDPATH= cd "$archives" && pwd -P)
fi
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
if [ "$("$zig" version)" != 0.17.0 ]; then echo 'Expected Zig 0.17.0' >&2; exit 1; fi
zigway_hash='zigway-0.1.0-alpha.4-J1VBH_6UDAB_K4K2qoaGf3VkKqRxg2T5tgKqJzWQsJ_P'
zyntra_hash='zyntra_ui-1.44.1-sgzbJL9GLABJOlz_u9WkQYOw3lVB2d7TJBbbXSHudeYN'
grep -Fq ".hash = \"$zigway_hash\"" "$repo/build.zig.zon" || { echo 'zigway manifest pin mismatch' >&2; exit 1; }
grep -Fq ".hash = \"$zyntra_hash\"" "$repo/build.zig.zon" || { echo 'zyntra_ui manifest pin mismatch' >&2; exit 1; }
umask 077
tmpbase=${TMPDIR:-/tmp}
case "$tmpbase" in /*) ;; *) echo 'TMPDIR must be absolute' >&2; exit 2 ;; esac
tmp=$(mktemp -d "$tmpbase/corex-deps.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
(cd "$repo/tools/zig" && "$zig" build install-extractor --prefix "$tmp/tools" -j2 --summary all)
extractor="$tmp/tools/bin/corex-extract-legacy"
for name in zigway zyntra_ui; do
    case "$name" in
        zigway) tag='v0.1.0-alpha.4'; upstream='Zigway'; expected=$zigway_hash ;;
        zyntra_ui) tag='v1.44.1'; upstream='ZyntraUI'; expected=$zyntra_hash ;;
    esac
    if [ -n "$archives" ]; then
        archive="$archives/$name.tar.gz"
    else
        archive="$tmp/$name.tar.gz"
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 30 --max-time 60 --max-filesize 16777216 \
            --output "$archive" "https://codeload.github.com/CeoMatheusDev/$upstream/tar.gz/refs/tags/$tag"
    fi
    "$extractor" "$name" "$archive" "$tmp/$name"
    actual=$(cd "$repo" && "$zig" fetch "$tmp/$name")
    if [ "$actual" != "$expected" ]; then
        echo "$name: Zig package hash mismatch: $actual" >&2
        exit 1
    fi
    echo "$name: verified $actual"
done

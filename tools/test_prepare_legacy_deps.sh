#!/bin/sh
# Integration tests for the shell/Zig preparer. Optional archive directory
# avoids downloading; all altered archives and install trees are temporary.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then echo 'usage: sh tools/test_prepare_legacy_deps.sh /absolute/path/to/zig [ARCHIVE_DIR]' >&2; exit 2; fi
zig=$1
case "$zig" in /*) [ -x "$zig" ] || exit 2 ;; *) exit 2 ;; esac
repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/corex-prepare-test.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$tmp/arquivos ação" "$tmp/scratch" "$tmp/outside cwd"
if [ "$#" -eq 2 ]; then
    cp "$2/zigway.tar.gz" "$2/zyntra_ui.tar.gz" "$tmp/arquivos ação/"
else
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 16777216 \
        --output "$tmp/arquivos ação/zigway.tar.gz" 'https://codeload.github.com/CeoMatheusDev/Zigway/tar.gz/refs/tags/v0.1.0-alpha.4'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 16777216 \
        --output "$tmp/arquivos ação/zyntra_ui.tar.gz" 'https://codeload.github.com/CeoMatheusDev/ZyntraUI/tar.gz/refs/tags/v1.44.1'
fi
check_cleanup() {
    for candidate in "$tmp/scratch"/corex-deps.*; do
        if [ -d "$candidate" ]; then echo 'temporary extraction directory leaked' >&2; exit 1; fi
    done
}
# Run with a different CWD and paths with spaces/non-ASCII characters.
(cd "$tmp/outside cwd" && TMPDIR="$tmp/scratch" sh "$repo/tools/prepare_legacy_deps.sh" --zig "$zig" --archive-dir "$tmp/arquivos ação")
check_cleanup
for name in zigway zyntra_ui; do
    cp "$tmp/arquivos ação/$name.tar.gz" "$tmp/original.tar.gz"
    printf x >> "$tmp/arquivos ação/$name.tar.gz"
    if TMPDIR="$tmp/scratch" sh "$repo/tools/prepare_legacy_deps.sh" --zig "$zig" --archive-dir "$tmp/arquivos ação" > "$tmp/out" 2>&1; then
        echo "modified $name archive passed" >&2; exit 1
    fi
    grep -q 'ArchiveHashMismatch' "$tmp/out"
    check_cleanup
    cp "$tmp/original.tar.gz" "$tmp/arquivos ação/$name.tar.gz"
done
# An empty argument must not silently switch to network mode.
if sh "$repo/tools/prepare_legacy_deps.sh" --zig "$zig" --archive-dir '' > "$tmp/out" 2>&1; then
    echo 'empty archive directory was accepted' >&2; exit 1
fi
grep -q usage "$tmp/out"
if TMPDIR=relative sh "$repo/tools/prepare_legacy_deps.sh" --zig "$zig" --archive-dir "$tmp/arquivos ação" > "$tmp/out" 2>&1; then
    echo 'relative TMPDIR was accepted' >&2; exit 1
fi
grep -q 'TMPDIR must be absolute' "$tmp/out"
printf '#!/bin/sh\necho 0.16.0\n' > "$tmp/wrong-zig"
chmod +x "$tmp/wrong-zig"
if TMPDIR="$tmp/scratch" sh "$repo/tools/prepare_legacy_deps.sh" --zig "$tmp/wrong-zig" --archive-dir "$tmp/arquivos ação" > "$tmp/out" 2>&1; then
    echo 'wrong Zig version was accepted' >&2; exit 1
fi
grep -q 'Expected Zig 0.17.0' "$tmp/out"
check_cleanup
# Deliberately wrong manifest is rejected before compilation or extraction.
mkdir -p "$tmp/mock-repo/tools"
cp "$repo/tools/prepare_legacy_deps.sh" "$tmp/mock-repo/tools/"
printf 'unrelated hash\n' > "$tmp/mock-repo/build.zig.zon"
if TMPDIR="$tmp/scratch" sh "$tmp/mock-repo/tools/prepare_legacy_deps.sh" --zig "$zig" --archive-dir "$tmp/arquivos ação" > "$tmp/out" 2>&1; then
    echo 'changed manifest pin was accepted' >&2; exit 1
fi
grep -q 'manifest pin mismatch' "$tmp/out"
check_cleanup
# Exercise package-hash failure without changing the real package cache output.
cat > "$tmp/fake-zig" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo 0.17.0 ;;
    fetch) echo incorrect-package-hash ;;
    *) exec "$REAL_ZIG" "$@" ;;
esac
EOF
chmod +x "$tmp/fake-zig"
if REAL_ZIG="$zig" TMPDIR="$tmp/scratch" sh "$repo/tools/prepare_legacy_deps.sh" --zig "$tmp/fake-zig" --archive-dir "$tmp/arquivos ação" > "$tmp/out" 2>&1; then
    echo 'incorrect Zig package hash was accepted' >&2; exit 1
fi
grep -q 'Zig package hash mismatch' "$tmp/out"
check_cleanup
echo 'OK: shell/Zig legacy preparer verifies archives, pins, package hashes and cleanup'

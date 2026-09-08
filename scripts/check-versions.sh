#!/bin/sh
# Fails when a version is written in two places and the two disagree.
# build.zig.zon is the source of truth for the project version and for Zig.
# Usage: scripts/check-versions.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CI=.github/workflows/ci.yml
REL=.github/workflows/release.yml
FW=scripts/firmware.sh
VOID=packaging/void-template.tmpl

fail=0
bad() { echo "$@" >&2; fail=1; }

# Sets VAL to the single value the pattern finds across the given files, or
# reports what it found instead and leaves VAL empty.
same() {
    label=$1
    pat=$2
    shift 2
    all=$(grep -hoE "$pat" "$@" | sort -u)
    if [ "$(printf '%s\n' "$all" | grep -c .)" = 1 ]; then
        VAL=$all
    else
        bad "$label: files disagree, found: $(printf '%s\n' "$all" | paste -sd,)"
        VAL=""
    fi
}

# Same, for a checksum identified by the file name it sits next to.
sums() {
    all=$(grep -h "$2" "$CI" "$REL" | grep -oE '[0-9a-f]{64}' | sort -u)
    if [ "$(printf '%s\n' "$all" | grep -c .)" = 1 ]; then
        VAL=$all
    else
        bad "$1: files disagree, found: $(printf '%s\n' "$all" | paste -sd,)"
        VAL=""
    fi
}

want() {
    [ -n "$2" ] || return 0
    [ "$2" = "$3" ] || bad "$1: $2, expected $3"
}

zon() { sed -n "s/^[[:space:]]*\.$1 = \"\([^\"]*\)\".*/\1/p" build.zig.zon; }

VERSION=$(zon version)
ZIG=$(zon minimum_zig_version)

echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || bad "build.zig.zon .version is \"$VERSION\", want a bare semver like 1.2.3"
echo "$ZIG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || bad "build.zig.zon .minimum_zig_version is \"$ZIG\", want a bare semver"

same "setup-zig" 'version: [0-9]+\.[0-9]+\.[0-9]+' "$CI" "$REL"
want "setup-zig" "${VAL#version: }" "$ZIG"

same "void template _zigver" '_zigver=[0-9]+\.[0-9]+\.[0-9]+' "$VOID"
want "void template _zigver" "${VAL#_zigver=}" "$ZIG"

same "Espressif Zig release" 'zig-espressif-bootstrap/releases/download/[0-9]+\.[0-9]+\.[0-9]+-xtensa' "$CI" "$REL" "$FW"
want "Espressif Zig release" "${VAL##*/}" "$ZIG-xtensa"

sums "Espressif Zig checksum" 'zig-xtensa.tar.xz'
XSUM=$VAL
same "Espressif Zig cache key" 'zig-xtensa-[0-9]+\.[0-9]+\.[0-9]+-xtensa-[0-9a-f]{8}' "$CI" "$REL"
[ -z "$XSUM" ] || want "Espressif Zig cache key" "$VAL" "zig-xtensa-$ZIG-xtensa-$(echo "$XSUM" | cut -c1-8)"

same "ESP-IDF image" 'espressif/idf:v[0-9.]+@sha256:[0-9a-f]{64}' "$CI" "$REL" "$FW"
same "nfpm version" 'NV=[0-9]+\.[0-9]+\.[0-9]+' "$CI" "$REL"
sums "nfpm checksum" 'nfpm.tgz'

# The recipes take the version from the tarball's build.zig.zon. Passing it in
# would let a recipe claim a version the source does not have.
for f in packaging/*.tmpl; do
    if grep -q -- '-Dversion' "$f"; then bad "$f passes -Dversion, let build.zig.zon decide"; fi
done

[ "$fail" = 0 ] || { echo "version check failed" >&2; exit 1; }
echo "versions agree: hcibridge $VERSION, zig $ZIG"

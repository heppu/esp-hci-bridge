#!/bin/sh
# Build deb/rpm/apk locally. Needs: zig, nfpm. Usage: packaging/build.sh [version]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}
export VERSION
zig build -Doptimize=ReleaseSafe "-Dversion=v$VERSION"
zig build gen "-Dversion=v$VERSION"
mkdir -p dist
cp zig-out/bin/hcibridge dist/hcibridge
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p deb -t dist/
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p rpm -t dist/
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p apk -t dist/
echo "built:"; ls -1 dist/

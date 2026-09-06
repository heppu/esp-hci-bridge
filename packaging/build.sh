#!/bin/sh
# Build deb/rpm/apk locally. Needs: zig, nfpm. Usage: packaging/build.sh [version]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if [ $# -ge 1 ]; then
    GIT_VERSION="v${1#v}"
else
    GIT_VERSION=$(git describe --tags 2>/dev/null || echo v0.0.0)
fi
# rpm and pacman reject hyphens in versions, so v0.10.2-3-gabc1234 becomes 0.10.2.3.gabc1234
VERSION=$(printf '%s' "${GIT_VERSION#v}" | tr - .)
export VERSION
zig build -Doptimize=ReleaseSafe "-Dversion=$GIT_VERSION"
zig build gen "-Dversion=$GIT_VERSION"
mkdir -p dist
cp zig-out/bin/hcibridge dist/hcibridge
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p deb -t dist/
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p rpm -t dist/
PKG_ARCH=amd64 nfpm pkg -f packaging/nfpm.yaml -p apk -t dist/
echo "built:"; ls -1 dist/

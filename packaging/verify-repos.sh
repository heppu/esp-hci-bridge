#!/bin/sh
# Installs hcibridge from the assembled repositories inside Debian, Fedora,
# and Alpine containers, over HTTP from this machine. Needs docker.
# Usage: packaging/verify-repos.sh <repo dir> [version]
set -eu
REPO=$(cd "$1" && pwd)
VER=${2:-}
PORT=${PORT:-48123}

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1
URL="http://127.0.0.1:$PORT"

run() {
    docker run --rm --network host -v "$REPO:/repo:ro" "$@"
}
check() {
    got=$(cat)
    echo "$got"
    [ -z "$VER" ] || echo "$got" | grep -q "$VER" || { echo "expected version $VER" >&2; exit 1; }
}

echo "== debian"
run -e DEBIAN_FRONTEND=noninteractive debian:stable-slim sh -euc "
  apt-get -qq update >/dev/null && apt-get -qq install -y ca-certificates >/dev/null
  install -m 644 /repo/hcibridge.gpg /etc/apt/keyrings/hcibridge.gpg 2>/dev/null || { mkdir -p /etc/apt/keyrings && install -m 644 /repo/hcibridge.gpg /etc/apt/keyrings/hcibridge.gpg; }
  echo 'deb [signed-by=/etc/apt/keyrings/hcibridge.gpg] $URL/deb stable main' > /etc/apt/sources.list.d/hcibridge.list
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y hcibridge >/dev/null
  hcibridge --version" | check

echo "== fedora"
run fedora:latest sh -euc "
  sed \"s|https://heppu.github.io/esp-hci-bridge|$URL|\" /repo/rpm/hcibridge.repo > /etc/yum.repos.d/hcibridge.repo
  dnf -q install -y hcibridge >/dev/null
  hcibridge --version" | check

echo "== alpine"
run alpine:3.22 sh -euc "
  cp /repo/alpine/heppu-esp-hci-bridge.rsa.pub /etc/apk/keys/
  echo '$URL/alpine' >> /etc/apk/repositories
  apk add -q hcibridge
  hcibridge --version" | check

echo "all repositories install"

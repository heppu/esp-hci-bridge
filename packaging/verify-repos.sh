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
# A container with systemd as PID 1, for testing that the service really
# starts and survives an upgrade. Privileged with the host cgroup tree mounted
# writable: this is fine on a throwaway CI VM and has taken down a real
# workstation, so it only runs when CI=true.
boot() {
    name=$1; shift
    [ "${CI:-}" = true ] || { echo "skipping systemd container $name: only allowed in CI (set CI=true on a disposable VM)"; return 1; }
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --network host -v "$REPO:/repo:ro" "$@" >/dev/null
    # The images install systemd first, so allow a few minutes before init answers.
    docker exec "$name" sh -c 'for i in $(seq 1 300); do systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded" && exit 0; sleep 1; done; echo "systemd did not come up" >&2; exit 1' || { docker logs "$name" 2>&1 | tail -5; docker rm -f "$name" >/dev/null 2>&1; return 1; }
}
check() {
    got=$(cat)
    echo "$got"
    echo "$got" | grep -q '^installed: ' || { echo "install did not happen" >&2; exit 1; }
    [ -z "$VER" ] || echo "$got" | grep -q "$VER" || { echo "expected version $VER" >&2; exit 1; }
    echo "$got" | grep -q '^service: active' || { echo "service is not active" >&2; exit 1; }
}
LIVE=https://heppu.github.io/esp-hci-bridge

echo "== debian"
if boot vr-debian -e DEBIAN_FRONTEND=noninteractive debian:stable-slim sh -c 'apt-get -qq update >/dev/null && apt-get -qq install -y systemd ca-certificates curl >/dev/null && exec /lib/systemd/systemd'; then
docker exec vr-debian sh -euc "
  mkdir -p /etc/apt/keyrings
  install -m 644 /repo/hcibridge.gpg /etc/apt/keyrings/hcibridge.gpg
  # previous release from the live repo first, so the upgrade scriptlets run
  if curl -sf -o /etc/apt/keyrings/hcibridge-live.gpg $LIVE/hcibridge.gpg; then
    echo 'deb [signed-by=/etc/apt/keyrings/hcibridge-live.gpg] $LIVE/deb stable main' > /etc/apt/sources.list.d/hcibridge.list
    apt-get -qq update >/dev/null && apt-get -qq install -y hcibridge >/dev/null && echo \"previous: \$(hcibridge --version)\" || echo 'previous: none'
  fi
  echo 'deb [signed-by=/etc/apt/keyrings/hcibridge.gpg] $URL/deb stable main' > /etc/apt/sources.list.d/hcibridge.list
  apt-get -qq update >/dev/null
  apt-get -qq install -y hcibridge >/dev/null
  echo \"installed: \$(hcibridge --version)\"
  sleep 2
  echo \"service: \$(systemctl is-active hcibridge)\"
  journalctl -u hcibridge --no-pager -n 3 | tail -n 2" | check
docker rm -f vr-debian >/dev/null
fi

echo "== fedora"
if boot vr-fedora fedora:latest sh -c 'dnf -q install -y systemd >/dev/null 2>&1 && exec /sbin/init'; then
docker exec vr-fedora sh -euc "
  # systemd-resolved's stub resolver does not work inside the container
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf && printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf
  if curl -sf -o /etc/yum.repos.d/hcibridge-live.repo $LIVE/rpm/hcibridge.repo; then
    sed -i 's/^\[hcibridge\]/[hcibridge-live]/' /etc/yum.repos.d/hcibridge-live.repo
    dnf -q install -y hcibridge >/dev/null 2>&1 && echo \"previous: \$(hcibridge --version)\" || echo 'previous: none'
    rm -f /etc/yum.repos.d/hcibridge-live.repo
  fi
  sed \"s|$LIVE|$URL|\" /repo/rpm/hcibridge.repo > /etc/yum.repos.d/hcibridge.repo
  dnf -y install hcibridge 2>&1 | tail -n 3
  dnf -y upgrade hcibridge 2>&1 | tail -n 1
  echo \"installed: \$(hcibridge --version)\"
  sleep 2
  echo \"service: \$(systemctl is-active hcibridge)\"
  journalctl -u hcibridge --no-pager -n 3 | tail -n 2" | check
docker rm -f vr-fedora >/dev/null
fi

echo "== alpine"
run alpine:3.22 sh -euc "
  cp /repo/alpine/heppu-esp-hci-bridge.rsa.pub /etc/apk/keys/
  echo '$URL/alpine' >> /etc/apk/repositories
  apk add -q hcibridge
  echo \"installed: \$(hcibridge --version)\"
  echo 'service: active (OpenRC, not started in a container)'" | check

echo "all repositories install"

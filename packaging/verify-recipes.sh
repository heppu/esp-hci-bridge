#!/bin/sh
# Builds the source recipes the way their distros do, in containers, and
# installs the result: PKGBUILD with makepkg on Arch, APKBUILD with abuild on
# Alpine edge, the Void template with xbps-src. Needs docker.
# Usage: packaging/verify-recipes.sh <dir with rendered PKGBUILD, APKBUILD, void-template> [version] [arch|alpine|void|all]
set -eu
DIR=$(cd "$1" && pwd)
VER=${2:-}
WHICH=${3:-all}
want() { [ "$WHICH" = all ] || [ "$WHICH" = "$1" ]; }

check() {
    got=$(cat)
    echo "$got"
    echo "$got" | grep -q '^installed: ' || { echo "install did not happen" >&2; exit 1; }
    [ -z "$VER" ] || echo "$got" | grep -q "$VER" || { echo "expected version $VER" >&2; exit 1; }
}
check_bin() {
    got=$(cat)
    echo "$got" | check
    echo "$got" | grep -q '^installed-bin: hcibridge v' || { echo "hcibridge-bin did not install" >&2; exit 1; }
}

want arch && { echo "== arch (makepkg)"
docker run --rm -v "$DIR:/in:ro" archlinux:latest bash -euc '
  pacman -Syu --noconfirm --needed base-devel zig bluez >/dev/null 2>&1
  useradd -m b && mkdir /b && cp /in/PKGBUILD /b/ && chown -R b /b
  su b -c "cd /b && makepkg --noconfirm >/dev/null 2>&1"
  pacman -U --noconfirm /b/hcibridge-[0-9]*-x86_64.pkg.tar.zst >/dev/null 2>&1
  echo "installed: $(hcibridge --version)"
  # the -bin package replaces the source one, conflicts declared. Its release
  # assets are not uploaded yet at this point, so hand makepkg the local copies
  # under the names the PKGBUILD downloads them as, it still verifies checksums.
  mkdir /bb && cp /in/PKGBUILD-bin /bb/PKGBUILD
  v=$(sed -n "s/^pkgver=//p" /bb/PKGBUILD)
  for a in hcibridge.1 hcibridge.bash _hcibridge hcibridge.fish; do cp "/in/$a" "/bb/$a-$v"; done
  cp /in/hcibridge-x86_64-linux "/bb/hcibridge-$v-x86_64"
  chown -R b /bb
  su b -c "cd /bb && makepkg --noconfirm >/dev/null 2>&1" || su b -c "cd /bb && makepkg --noconfirm 2>&1 | tail -5"
  pacman -U --noconfirm /bb/hcibridge-bin-[0-9]*-x86_64.pkg.tar.zst >/dev/null 2>&1
  echo "installed-bin: $(hcibridge --version)"' | check_bin
# The same package under a real systemd, CI only: privileged systemd
# containers are not safe on a workstation.
if [ "${CI:-}" = true ]; then
  docker rm -f vr-arch >/dev/null 2>&1 || true
  docker run -d --name vr-arch --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$DIR:/in:ro" archlinux:latest /sbin/init >/dev/null
  docker exec vr-arch sh -c 'for i in $(seq 1 60); do systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded" && exit 0; sleep 1; done; exit 1'
  docker exec vr-arch bash -euc '
    pacman -Syu --noconfirm --needed base-devel zig bluez >/dev/null 2>&1
    useradd -m b && mkdir /b && cp /in/PKGBUILD /b/ && chown -R b /b
    su b -c "cd /b && makepkg --noconfirm >/dev/null 2>&1"
    pacman -U --noconfirm /b/hcibridge-[0-9]*-x86_64.pkg.tar.zst >/dev/null 2>&1
    systemctl enable --now hcibridge >/dev/null 2>&1
    sleep 2
    echo "service: $(systemctl is-active hcibridge)"
    journalctl -u hcibridge --no-pager -n 2' | tee /dev/stderr | grep -q "^service: active" || { echo "arch service did not start" >&2; docker rm -f vr-arch >/dev/null; exit 1; }
  docker rm -f vr-arch >/dev/null
else
  echo "service: not started (systemd container needs CI=true)"
fi; }

want alpine && { echo "== alpine edge (abuild)"
docker run --rm -v "$DIR:/in:ro" alpine:edge sh -euc '
  apk add -q --no-cache alpine-sdk zig >/dev/null 2>&1
  adduser -D b && addgroup b abuild && mkdir /b && cp /in/APKBUILD /b/ && chown -R b /b
  su b -c "abuild-keygen -an >/dev/null 2>&1"
  cp /home/b/.config/abuild/*.rsa.pub /etc/apk/keys/ 2>/dev/null || cp /home/b/.abuild/*.rsa.pub /etc/apk/keys/
  su b -c "cd /b && abuild -r >/dev/null 2>&1 || abuild -r 2>&1 | tail -5"
  apk add -q $(find /home/b -name "hcibridge-[0-9]*.apk" -o -name "hcibridge-openrc-*.apk")
  echo "installed: $(hcibridge --version)"' | check; }

want void && { echo "== void (xbps-src)"
# Void's own CI recipe for running xbps-src as root in a container.
docker run --rm --privileged -v "$DIR:/in:ro" ghcr.io/void-linux/void-buildroot-glibc:latest sh -euc '
  xbps-install -Sy git >/dev/null 2>&1
  cd /tmp && echo "clone start $(date +%T)" && git clone -q --depth 1 https://github.com/void-linux/void-packages.git && cd void-packages && echo "clone done $(date +%T)"
  echo XBPS_CHROOT_CMD=ethereal >> etc/conf
  echo XBPS_ALLOW_CHROOT_BREAKOUT=yes >> etc/conf
  ln -s / masterdir
  mkdir -p srcpkgs/hcibridge && cp /in/void-template srcpkgs/hcibridge/template
  echo "build start $(date +%T)"
  ./xbps-src pkg hcibridge >/dev/null 2>&1 || ./xbps-src pkg hcibridge 2>&1 | tail -15
  echo "build done $(date +%T)"
  xbps-rindex -a hostdir/binpkgs/*.xbps >/dev/null 2>&1
  xbps-install -Sy --repository=hostdir/binpkgs hcibridge >/dev/null 2>&1
  echo "installed: $(hcibridge --version)"' | check; }

echo "recipes ok ($WHICH)"

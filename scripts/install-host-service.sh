#!/bin/sh
# Installs the hcibridge daemon as a service. Detects systemd, OpenRC, runit or
# s6 and sets up the matching unit. Run as root: doas scripts/install-host-service.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

build() {
    cd "$ROOT"
    zig build -Doptimize=ReleaseSafe "-Dversion=$(git describe --tags --always 2>/dev/null || echo dev)"
}

if [ "${1:-}" = --build-only ]; then
    build
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: doas $0" >&2
    exit 1
fi

echo "building release binary"
# Build as the invoking user so zig-cache and zig-out in the checkout stay theirs.
BUILD_USER=${SUDO_USER:-${DOAS_USER:-}}
if [ -n "$BUILD_USER" ] && [ "$BUILD_USER" != root ]; then
    su -s /bin/sh "$BUILD_USER" -c "'$ROOT/scripts/install-host-service.sh' --build-only"
else
    build
fi
install -m 0755 "$ROOT/zig-out/bin/hcibridge" /usr/bin/hcibridge

# Stop any hand-run in-tree daemon so it does not fight the service for /dev/vhci.
# Anchored so it leaves hcibridge-sim and the installed binary alone.
pkill -f '(^|/)zig-out/bin/hcibridge( |$)' 2>/dev/null || true

# Shell completions and man page, generated from the binary (single source).
BIN=/usr/bin/hcibridge
if [ -d /usr/share/bash-completion/completions ]; then
    "$BIN" completions bash > /usr/share/bash-completion/completions/hcibridge
fi
if [ -d /usr/share/zsh/site-functions ]; then
    "$BIN" completions zsh > /usr/share/zsh/site-functions/_hcibridge
fi
if [ -d /usr/share/fish/vendor_completions.d ]; then
    "$BIN" completions fish > /usr/share/fish/vendor_completions.d/hcibridge.fish
fi
install -d /usr/local/share/man/man1
"$BIN" man > /usr/local/share/man/man1/hcibridge.1
command -v mandb >/dev/null 2>&1 && mandb -q >/dev/null 2>&1 || true
command -v makewhatis >/dev/null 2>&1 && makewhatis >/dev/null 2>&1 || true
echo "installed completions and man page"

# Load the vhci module at boot (systemd-modules-load and most others read this).
install -d /etc/modules-load.d
install -m 0644 "$ROOT/host/modules-load.conf" /etc/modules-load.d/hci_vhci.conf
modprobe hci_vhci 2>/dev/null || true

# Native layered config: /etc/hcibridge/hcibridge.conf + hcibridge.conf.d/*.conf
install -d /etc/hcibridge/hcibridge.conf.d
[ -f /etc/hcibridge/hcibridge.conf ] || install -m 0644 "$ROOT/host/config/hcibridge.conf" /etc/hcibridge/hcibridge.conf

if [ -d /run/systemd/system ]; then
    echo "detected: systemd"
    install -m 0644 "$ROOT/host/systemd/hcibridge.service" /etc/systemd/system/hcibridge.service
    [ -f /etc/default/hcibridge ] || install -m 0644 "$ROOT/host/systemd/hcibridge.env" /etc/default/hcibridge
    systemctl daemon-reload
    systemctl enable --now hcibridge.service
    systemctl --no-pager status hcibridge.service || true

elif command -v rc-update >/dev/null 2>&1; then
    echo "detected: OpenRC"
    install -m 0755 "$ROOT/host/openrc/hcibridged" /etc/init.d/hcibridged
    [ -f /etc/conf.d/hcibridged ] || install -m 0644 "$ROOT/host/openrc/hcibridged.confd" /etc/conf.d/hcibridged
    rc-update add hcibridged default
    rc-service hcibridged restart
    rc-service hcibridged status || true

elif command -v sv >/dev/null 2>&1; then
    echo "detected: runit"
    install -d /etc/sv/hcibridge/log
    install -m 0755 "$ROOT/host/runit/hcibridge/run" /etc/sv/hcibridge/run
    [ -f /etc/sv/hcibridge/conf ] || install -m 0644 "$ROOT/host/runit/hcibridge/conf" /etc/sv/hcibridge/conf
    install -m 0755 "$ROOT/host/runit/hcibridge/log/run" /etc/sv/hcibridge/log/run
    install -d /var/log/hcibridge
    for d in /var/service /etc/service /run/runit/service /etc/runit/runsvdir/current; do
        if [ -d "$d" ]; then ln -sf /etc/sv/hcibridge "$d/hcibridge"; echo "linked into $d"; break; fi
    done
    sleep 2
    sv restart hcibridge 2>/dev/null || echo "run: sv up hcibridge (once runsv picks it up)"

elif command -v s6-rc >/dev/null 2>&1 || command -v s6-svscan >/dev/null 2>&1; then
    echo "detected: s6"
    dest=/etc/s6/sv/hcibridge
    install -d "$dest"
    install -m 0755 "$ROOT/host/s6/hcibridge/run" "$dest/run"
    [ -f "$dest/conf" ] || install -m 0644 "$ROOT/host/s6/hcibridge/conf" "$dest/conf"
    install -m 0644 "$ROOT/host/s6/hcibridge/type" "$dest/type"
    echo "installed s6 service dir at $dest"
    echo "add it to your s6-rc source db and reload, or symlink into your scan dir,"
    echo "then: s6-rc -u change hcibridge  (or  s6-svscanctl -a <scandir>)"

else
    echo "no known init system detected. run it yourself:"
    echo "  modprobe hci_vhci"
    echo "  /usr/bin/hcibridge run"
fi

echo
echo "done. binary: /usr/bin/hcibridge"
echo "check bridges:  hcibridge list"
echo "if bluez does not show controllers, restart the bluetooth service once."

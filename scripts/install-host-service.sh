#!/bin/sh
# Installs hcibridged as an OpenRC service. Run as root: doas scripts/install-host-service.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: doas $0" >&2
    exit 1
fi

echo "building release binary"
su - "${SUDO_USER:-${DOAS_USER:-$(logname 2>/dev/null || echo root)}}" -c "cd '$ROOT' && zig build -Doptimize=ReleaseSafe" 2>/dev/null \
    || (cd "$ROOT" && zig build -Doptimize=ReleaseSafe)

install -m 0755 "$ROOT/zig-out/bin/hcibridged" /usr/local/bin/hcibridged
install -m 0755 "$ROOT/host/openrc/hcibridged" /etc/init.d/hcibridged
if [ ! -f /etc/conf.d/hcibridged ]; then
    install -m 0644 "$ROOT/host/openrc/hcibridged.confd" /etc/conf.d/hcibridged
    echo "installed /etc/conf.d/hcibridged (edit BRIDGE_HOST there if the board moves)"
else
    echo "kept existing /etc/conf.d/hcibridged"
fi

# hci_vhci at boot
echo hci_vhci > /etc/modules-load.d/hci_vhci.conf

rc-update add hcibridged default
rc-service hcibridged restart

sleep 3
echo "--- status ---"
rc-service hcibridged status || true
echo "--- adapter ---"
bluetoothctl list 2>/dev/null || true
echo
echo "done. logs: /var/log/hcibridged.log"
echo "if bluez does not show the controller, run: doas rc-service bluetooth restart"

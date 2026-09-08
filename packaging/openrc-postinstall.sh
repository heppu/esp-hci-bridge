#!/bin/sh
set -e
modprobe hci_vhci 2>/dev/null || true

# The old layout, /etc/hcibridge/config and config.d. The board keys written
# by `hcibridge claim` live in the drop-in dir, so both have to come along or
# boards stop attaching. The old main file becomes a drop-in, which merges on
# top of the packaged default instead of overwriting it.
if [ -f /etc/hcibridge/config ]; then
    mkdir -p /etc/hcibridge/hcibridge.conf.d
    mv /etc/hcibridge/config /etc/hcibridge/hcibridge.conf.d/00-old-config.conf
    echo "moved /etc/hcibridge/config to /etc/hcibridge/hcibridge.conf.d/00-old-config.conf"
fi
if [ -d /etc/hcibridge/config.d ]; then
    mkdir -p /etc/hcibridge/hcibridge.conf.d
    for f in /etc/hcibridge/config.d/*.conf; do
        [ -e "$f" ] || continue
        b=${f##*/}
        [ -e "/etc/hcibridge/hcibridge.conf.d/$b" ] || mv "$f" "/etc/hcibridge/hcibridge.conf.d/$b"
    done
    rmdir /etc/hcibridge/config.d 2>/dev/null || true
    echo "moved the drop-ins from /etc/hcibridge/config.d to /etc/hcibridge/hcibridge.conf.d"
fi
# apk passes the new version as $1 and, on upgrade only, the old version as $2
if command -v rc-service >/dev/null 2>&1; then
    if [ -z "${2:-}" ]; then
        rc-update add hcibridged default || true
        rc-service hcibridged start || true
    elif rc-service hcibridged status >/dev/null 2>&1; then
        rc-service hcibridged restart || true
    fi
fi
echo "hcibridge installed. Runs in discovery mode; edit /etc/hcibridge/hcibridge.conf to configure."

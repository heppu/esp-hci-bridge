#!/bin/sh
set -e
modprobe hci_vhci 2>/dev/null || true
# apk passes the new version as $1 and, on upgrade only, the old version as $2
if command -v rc-service >/dev/null 2>&1; then
    if [ -z "${2:-}" ]; then
        rc-update add hcibridged default || true
        rc-service hcibridged start || true
    elif rc-service hcibridged status >/dev/null 2>&1; then
        rc-service hcibridged restart || true
    fi
fi
echo "hcibridge installed. Runs in discovery mode; edit /etc/hcibridge/config to configure."

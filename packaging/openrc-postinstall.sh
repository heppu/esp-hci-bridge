#!/bin/sh
set -e
modprobe hci_vhci 2>/dev/null || true
if command -v rc-update >/dev/null 2>&1; then
    rc-update add hcibridged default || true
    rc-service hcibridged restart || true
fi
echo "hcibridge installed. Runs in discovery mode; edit /etc/hcibridge/config to configure."

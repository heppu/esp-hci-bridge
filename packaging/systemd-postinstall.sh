#!/bin/sh
set -e
modprobe hci_vhci 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable hcibridge.service || true
    systemctl start hcibridge.service || true
fi
echo "hcibridge installed. Runs in discovery mode; edit /etc/hcibridge/config to configure."

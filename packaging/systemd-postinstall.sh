#!/bin/sh
set -e
modprobe hci_vhci 2>/dev/null || true
# rpm passes 1 on install and 2 on upgrade, deb passes configure plus the old version on upgrade
fresh=0
case "${1:-}" in
    1) fresh=1 ;;
    configure) [ -n "${2:-}" ] || fresh=1 ;;
esac
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    if [ "$fresh" = 1 ]; then
        systemctl enable hcibridge.service || true
        systemctl start hcibridge.service || true
    elif systemctl is-active --quiet hcibridge.service; then
        systemctl restart hcibridge.service || true
    fi
fi
echo "hcibridge installed. Runs in discovery mode; edit /etc/hcibridge/config to configure."

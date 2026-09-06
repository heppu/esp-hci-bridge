#!/bin/sh
set -e
# rpm passes 0 on erase and 1 on upgrade, deb passes remove or upgrade
case "${1:-}" in
    0|remove) ;;
    *) exit 0 ;;
esac
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop hcibridge.service || true
    systemctl disable hcibridge.service || true
fi

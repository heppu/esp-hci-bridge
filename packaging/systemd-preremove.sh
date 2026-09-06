#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop hcibridge.service || true
    systemctl disable hcibridge.service || true
fi

#!/bin/sh
set -e
if command -v rc-service >/dev/null 2>&1; then
    rc-service hcibridged stop || true
    rc-update del hcibridged default || true
fi

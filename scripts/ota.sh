#!/bin/sh
# Pushes a firmware image to a running bridge over HTTP.
# Usage: scripts/ota.sh <ip|host> [image.bin]
set -eu
HOST=$1
IMG=${2:-$(dirname "$0")/../firmware/build/esp-hci-bridge.bin}
echo "before: $(curl -s "http://$HOST/")"
curl -sS --fail -X POST --data-binary "@$IMG" -H 'Content-Type: application/octet-stream' "http://$HOST/ota"
echo "waiting for reboot"
sleep 8
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if out=$(curl -s --max-time 2 "http://$HOST/"); then
        echo "after: $out"
        exit 0
    fi
    sleep 2
done
echo "bridge did not come back" >&2
exit 1

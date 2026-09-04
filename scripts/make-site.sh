#!/bin/sh
# Assembles the static flashing site: web/ plus firmware binaries and a
# generated ESP Web Tools manifest. Usage: scripts/make-site.sh <version> <build dir> <out dir>
set -eu
VERSION=$1
BUILD=$2
OUT=$3

mkdir -p "$OUT/firmware"
cp web/index.html "$OUT/"
cp "$BUILD/bootloader/bootloader.bin" "$OUT/firmware/"
cp "$BUILD/partition_table/partition-table.bin" "$OUT/firmware/"
cp "$BUILD/esp-hci-bridge.bin" "$OUT/firmware/"

cat > "$OUT/manifest.json" <<JSON
{
  "name": "esp-hci-bridge",
  "version": "$VERSION",
  "built": "$(date -u +%Y-%m-%dT%H:%MZ)",
  "new_install_prompt_erase": true,
  "builds": [
    {
      "chipFamily": "ESP32",
      "parts": [
        { "path": "firmware/bootloader.bin", "offset": 4096 },
        { "path": "firmware/partition-table.bin", "offset": 32768 },
        { "path": "firmware/esp-hci-bridge.bin", "offset": 65536 }
      ]
    }
  ]
}
JSON
echo "site assembled in $OUT"

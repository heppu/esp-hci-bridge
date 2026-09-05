#!/bin/sh
# Assembles the static flashing site: web/ plus firmware binaries and a
# generated ESP Web Tools manifest. Offsets come from the build's flash_args
# so the manifest always matches the partition table.
# Usage: scripts/make-site.sh <version> <build dir> <out dir>
set -eu
VERSION=$1
BUILD=$2
OUT=$3

mkdir -p "$OUT/firmware"
cp web/index.html "$OUT/"

parts=""
while read -r offset file; do
    case "$offset" in 0x*) ;; *) continue ;; esac
    name=$(basename "$file")
    cp "$BUILD/$file" "$OUT/firmware/$name"
    dec=$(printf '%d' "$offset")
    parts="$parts${parts:+,}
        { \"path\": \"firmware/$name\", \"offset\": $dec }"
done < "$BUILD/flash_args"

cat > "$OUT/manifest.json" <<JSON
{
  "name": "esp-hci-bridge",
  "version": "$VERSION",
  "built": "$(date -u +%Y-%m-%dT%H:%MZ)",
  "new_install_prompt_erase": true,
  "builds": [
    {
      "chipFamily": "ESP32",
      "parts": [$parts
      ]
    }
  ]
}
JSON
echo "site assembled in $OUT"

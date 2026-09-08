#!/bin/sh
# Assembles the static flashing site for one or more board presets.
# Usage: scripts/make-site.sh <version> <out dir> <board>=<build dir> [<board>=<build dir> ...]
# Emits out/firmware/<board>/*.bin, out/manifest-<board>.json, out/boards.json.
# Offsets come from each build's flash_args so manifests match the partition table.
set -eu
VERSION=$1
OUT=$2
shift 2
[ $# -ge 1 ] || { echo "need at least one <board>=<build dir>" >&2; exit 1; }

mkdir -p "$OUT"
cp web/index.html "$OUT/"
BUILT=$(date -u +%Y-%m-%dT%H:%MZ)

boards_json="["
first=1
for spec in "$@"; do
    board=${spec%%=*}
    build=${spec#*=}
    mkdir -p "$OUT/firmware/$board"
    parts=""
    while read -r offset file; do
        case "$offset" in 0x*) ;; *) continue ;; esac
        name=$(basename "$file")
        cp "$build/$file" "$OUT/firmware/$board/$name"
        dec=$(printf '%d' "$offset")
        parts="$parts${parts:+,}
        { \"path\": \"firmware/$board/$name\", \"offset\": $dec }"
    done < "$build/flash_args"

    cat > "$OUT/manifest-$board.json" <<JSON
{
  "name": "hcibridge ($board)",
  "version": "$VERSION",
  "built": "$BUILT",
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
    desc=$(sed -n '1s/^# *//p' "firmware/boards/$board.conf" | sed 's/"/\\"/g')
    [ "$first" = 1 ] || boards_json="$boards_json,"
    boards_json="$boards_json{\"id\":\"$board\",\"desc\":\"$desc\"}"
    first=0
done
printf '%s]\n' "$boards_json" > "$OUT/boards.json"
# Default manifest for anything still pointing at manifest.json (first board).
cp "$OUT/manifest-${1%%=*}.json" "$OUT/manifest.json"
echo "site assembled in $OUT ($#) board(s)"

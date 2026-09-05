#!/bin/sh
# Runs idf.py inside the ESP-IDF container with the Espressif Zig toolchain.
# Usage: scripts/firmware.sh build | flash | monitor | menuconfig | ...
# Set PORT=/dev/ttyUSB0 for flash and monitor.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDF_IMAGE=${IDF_IMAGE:-espressif/idf:v5.5.5}
ZIG_DIR="$ROOT/.tools/zig-xtensa"
ZIG_URL=${ZIG_URL:-https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz}

if [ ! -x "$ZIG_DIR/zig" ]; then
    echo "fetching Espressif Zig into $ZIG_DIR"
    mkdir -p "$ZIG_DIR"
    curl -sSL "$ZIG_URL" | tar -xJ -C "$ZIG_DIR" --strip-components=1
fi

DEVICE_ARGS=""
if [ -n "${PORT:-}" ]; then
    # The container runs as the host user, who is often not in dialout.
    # Pass the device's group in so the port is readable inside.
    DEVICE_ARGS="--device=$PORT --group-add=$(stat -c %g "$PORT")"
fi
TTY_ARGS=""
if [ -t 0 ]; then
    TTY_ARGS="-it"
fi

# shellcheck disable=SC2086
exec docker run --rm $TTY_ARGS $DEVICE_ARGS \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e ZIG=/project/.tools/zig-xtensa/zig \
    -v "$ROOT":/project \
    -w /project/firmware \
    "$IDF_IMAGE" idf.py ${PORT:+-p "$PORT"} "$@"

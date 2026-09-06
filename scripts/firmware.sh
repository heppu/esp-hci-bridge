#!/bin/sh
# Runs idf.py inside the ESP-IDF container with the Espressif Zig toolchain.
# Usage: [BOARD=<preset>] scripts/firmware.sh build | flash | monitor | menuconfig | ...
# Presets: firmware/boards/*.conf (default olimex-esp32-poe)
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

# Board preset: firmware/boards/<BOARD>.conf layered on sdkconfig.defaults.
# Each board gets its own build dir and sdkconfig so presets never bleed.
BOARD=${BOARD:-olimex-esp32-poe}
[ -f "$ROOT/firmware/boards/$BOARD.conf" ] || { echo "unknown BOARD=$BOARD; see firmware/boards/" >&2; exit 1; }
BUILD_DIR="build-$BOARD"
# IDF only reads defaults when creating sdkconfig; drop a stale one so preset
# or defaults changes take effect.
if [ -f "$ROOT/firmware/$BUILD_DIR/sdkconfig" ]; then
    for f in "$ROOT/firmware/sdkconfig.defaults" "$ROOT/firmware/boards/$BOARD.conf"; do
        if [ "$f" -nt "$ROOT/firmware/$BUILD_DIR/sdkconfig" ]; then
            echo "config changed, regenerating sdkconfig for $BOARD"
            rm -f "$ROOT/firmware/$BUILD_DIR/sdkconfig"
            break
        fi
    done
fi
IDF_ARGS="-B $BUILD_DIR -DSDKCONFIG=$BUILD_DIR/sdkconfig -DSDKCONFIG_DEFAULTS=sdkconfig.defaults;boards/$BOARD.conf"

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
    "$IDF_IMAGE" idf.py $IDF_ARGS ${PORT:+-p "$PORT"} "$@"

# Development

## How it works

The ESP32 runs only the Bluetooth controller (radio and link layer) and
forwards raw HCI packets over TCP. The PC daemon feeds them into the kernel's
virtual HCI device (`/dev/vhci`), so BlueZ sees an ordinary local controller.
Boards announce themselves over UDP and the daemon attaches each one to its
own adapter. The network hop adds well under a millisecond, so latency is set
by the Bluetooth link itself.

## Build the PC tool

Needs [Zig](https://ziglang.org) 0.16. The result is one static binary with no
libc, cross-compiled for x86_64, aarch64, and armv7.

```sh
zig build -Doptimize=ReleaseSafe   # zig-out/bin/hcibridge
zig build test                     # test suite
zig build release                  # static binaries for all target arches
zig build gen                      # man page and shell completions
```

Distro packages come from `packaging/build.sh` (needs `zig` and
[`nfpm`](https://nfpm.goreleaser.com/)). One nfpm config produces deb, rpm,
and apk. `PKGBUILD`, `APKBUILD`, and the Void template build from source.

To install without a package, `sudo scripts/install-host-service.sh` builds the
binary and sets up the service for the init system it detects (systemd,
OpenRC, runit, or s6).

## Build the firmware

Needs Docker. The script pulls the ESP-IDF toolchain and a Zig with Xtensa
support.

```sh
scripts/firmware.sh build                              # default preset olimex-esp32-poe
BOARD=generic-wifi scripts/firmware.sh build           # another preset
PORT=/dev/ttyUSB0 scripts/firmware.sh flash
PORT=/dev/ttyUSB0 scripts/firmware.sh monitor
PROJECT_VER=v1.2.3-test scripts/firmware.sh build      # custom version string
```

Each preset builds into `firmware/build-<board>/`. Images are signed. Without
`firmware/secure_boot_signing_key.pem` the script generates a throwaway
development key, and boards running release firmware will reject that image
over the network. Flash such builds over USB, or put the release key in place.

The bridge logic is Zig (`firmware/main/bridge.zig`). C is limited to ESP-IDF
setup: `glue.c` (startup, sockets, discovery), `net.c` (Ethernet and WiFi),
`ota.c` (HTTP status, update, claim), `auth.c` (board key). Pin defaults are in
`firmware/main/Kconfig.projbuild`.

### Boot trace

Startup progress is kept in RTC memory, which survives a reset. After a crash
the next image reports it in the status JSON as `prev_stage` and `reset`
(an `esp_reset_reason` value). Stages: 1 boot, 2 to 3 key init, 4 Bluetooth
controller up, 5 network start, 6 to 7 bridge tasks, 8 HTTP server up, 9 got
an IP address, 10 first HTTP request served. This is the way to debug a board
that has no serial cable attached.

### Adding a board preset

Copy a file in `firmware/boards/`, set the PHY (LAN87xx, RTL8201, IP101,
KSZ80xx, DP83848), MDC/MDIO/power pins, PHY address, and RMII clock mode, and
build with `BOARD=<name>`. Add the preset to the matrix in
`.github/workflows/release.yml` and to `scripts/make-site.sh` so the flasher
and release carry it.

## Protocol

TCP carries HCI in H4 framing: one indicator byte, the HCI header, then the
payload. Every connection starts with a mutual HMAC-SHA256 challenge and
response over the board key. One client per board, a new authenticated
connection replaces the old one. A dead peer is dropped after about ten
seconds by TCP keepalive and user timeout.

Boards broadcast `ESPHCI1 ANNOUNCE <bdaddr> <port> <name> <sig>` over UDP and
answer probes. The signature covers the board's own IP address, so a captured
announce cannot be replayed from elsewhere.

HTTP requests that change the board (`/ota`, `/reboot`, `/unclaim`) carry two
proofs computed with the key over a nonce the board publishes on `GET /`. The
nonce changes after every accepted request, so a captured request cannot be
replayed. `/ota` checks the first proof, over the content length, before
touching flash, and the second, over the body hash, before activating the
image.

The key itself comes from an X25519 exchange at claim time:
`PSK = SHA256(shared secret)`. The Zig side is in `common/auth.zig`, the C
side in `firmware/main/auth.c`, and `common/auth.zig` carries fixed test
vectors that both must match.

## Repository layout

| path | what |
|---|---|
| `common/h4.zig` | HCI H4 packet framing, shared by firmware and host |
| `common/discovery.zig` | the UDP discovery protocol |
| `common/auth.zig` | board key: handshake, signatures, HTTP proofs, claim |
| `firmware/` | ESP32 firmware, Zig logic plus ESP-IDF glue |
| `host/` | the `hcibridge` binary: daemon, CLI, config |
| `host/spec.zig`, `host/settings.zig` | single sources for the CLI, help, man page, completions, and settings |
| `host/sim.zig` | a simulated board used by the integration tests |
| `packaging/` | nfpm config, distro recipes, service scriptlets |
| `web/` | the browser flasher page |
| `scripts/` | firmware build wrapper, site assembly, service installer |

## Releasing

Push a `v*` tag on a commit that is on `main`. The workflow refuses tags that
are not, builds every preset with the release signing key from the
`FIRMWARE_SIGNING_KEY` secret, packages the PC tool, publishes `SHA256SUMS` and
provenance attestations, and deploys the flasher page. Losing the signing key
means no board can be updated over the network again, so keep a copy outside
CI.

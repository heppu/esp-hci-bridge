# esp-hci-bridge

Use Bluetooth devices that are nowhere near your computer.

A tiny, cheap ESP32 board acts as a remote Bluetooth radio. Put it wherever your
game controller, keyboard, or mouse actually is (the living room, 100 m of
Ethernet away) and your Linux PC talks to those devices as if the Bluetooth
adapter were built in. Pairing, input, and reconnection all work through normal
BlueZ, because to your PC it *is* a normal Bluetooth controller.

Built for playing PC games on the couch: the PC drives the TV over a long HDMI
cable, and this puts the gamepad's Bluetooth where you are sitting instead of
back at the machine.

```
  gamepad / keyboard / mouse
        │  Bluetooth
   ┌────┴─────┐        HCI over your LAN         ┌──────────────────┐
   │ ESP32    │  ───────────────────────────▶   │ your Linux PC     │
   │ (radio)  │        (Ethernet / PoE)          │ hcibridge → BlueZ │
   └──────────┘                                  └──────────────────┘
```

## What you need

- An **Olimex ESP32-POE** board (original ESP32, powered over Ethernet).
- A **Linux PC** with BlueZ and the `hci_vhci` kernel module (standard).
- Both on the **same network**.

## Get started

### 1. Flash the board

Open the **[web flasher](https://heppu.github.io/esp-hci-bridge/)** in Chrome,
Chromium, or Edge, plug the board into that computer over USB, and click Install.
That is the whole firmware step.

(Prefer the terminal? Every [release](https://github.com/heppu/esp-hci-bridge/releases/latest)
also has the raw `.bin` files and an `esptool` command.)

### 2. Install on your PC

Grab the package for your distro and architecture from the
[latest release](https://github.com/heppu/esp-hci-bridge/releases/latest):

```sh
sudo dpkg -i hcibridge_*_amd64.deb                      # Debian / Ubuntu
sudo rpm -i hcibridge-*.x86_64.rpm                      # Fedora / RHEL
sudo apk add --allow-untrusted hcibridge_*_x86_64.apk   # Alpine
```

Arch users have a `PKGBUILD`, Void a `void-template`, all on the release page.
The package installs a background service that starts on boot and automatically
finds any board on your network. Nothing else to configure.

### 3. Pair your devices

Check the board showed up, then pair as usual:

```sh
hcibridge list                 # your boards and their firmware version
bluetoothctl                   # scan / pair / connect, as with any adapter
```

Each board appears as its own controller, so its pairings stay with it.

## Managing boards

`hcibridge` is a single command. The service runs `hcibridge run`; you use the
rest by hand:

| command | what it does |
|---|---|
| `hcibridge list` | discover boards and show firmware versions |
| `hcibridge status <ip>` | full status of one board |
| `hcibridge update <ip\|all> <file.bin>` | update firmware over the network |
| `hcibridge run` | the daemon (started by the service) |

There is a man page (`man hcibridge`) and shell completions for bash, zsh, and
fish, all installed by the package.

### Updating firmware

No cable needed after the first flash. Download the new `esp-hci-bridge.bin`
from a release and:

```sh
hcibridge update all esp-hci-bridge.bin
```

Boards keep two firmware slots and roll back automatically if an update fails to
come online.

## Configuration

Everything works out of the box in discovery mode. To tune it, edit
`/etc/hcibridge/config` (drop-in fragments in `/etc/hcibridge/config.d/*.conf`
also apply). Every setting can equally be an environment variable or a
command-line flag; they win in that order:

```
flag  >  environment variable  >  config file  >  built-in default
```

| setting | config key | flag | environment |
|---|---|---|---|
| auto-discovery on/off | `discovery` | `--discovery` / `--no-discovery` | `HCIBRIDGE_DISCOVERY` |
| accept only this IP range | `subnet` | `--subnet` | `HCIBRIDGE_SUBNET` |
| pin specific boards | `client` | `--client` / `--host` | `HCIBRIDGE_CLIENTS` |
| allow only these devices | `allow` | `--allow` | `HCIBRIDGE_ALLOW` |
| block devices | `deny` | `--deny` | `HCIBRIDGE_DENY` |

`allow`/`deny` take a board's Bluetooth address (the BDADDR from
`hcibridge list`). The installed `/etc/hcibridge/config` documents every option.

## More than one board

Discovery handles as many boards as you like at once: plug another in and it
shows up on its own, unplug one and its adapter disappears. Put one bridge in
each room, or set `subnet` so the daemon only adopts boards on your own network.

---

## How it works

The ESP32 runs only the Bluetooth *controller* (the radio and link layer) and
forwards raw HCI packets over TCP. The PC daemon feeds those into the kernel's
virtual HCI device (`/dev/vhci`), so BlueZ sees an ordinary local controller.
Boards announce themselves over UDP; the daemon attaches each to its own
adapter. The network hop adds well under a millisecond, so latency is dominated
by the Bluetooth link itself, exactly as with a built-in adapter.

## Build from source

Needs [Zig](https://ziglang.org) 0.16. The PC side is one static binary with no
libc, cross-compiled for x86_64, aarch64, and armv7.

```sh
zig build -Doptimize=ReleaseSafe   # -> zig-out/bin/hcibridge
zig build test                     # run the test suite
zig build release                  # static binaries for all target arches
zig build gen                      # man page + shell completions
```

Build the distro packages locally with `packaging/build.sh` (needs `zig` and
[`nfpm`](https://nfpm.goreleaser.com/)). The `deb`, `rpm`, and `apk` come from
one nfpm config; `PKGBUILD`, `APKBUILD`, and the Void template build from source.

To install without a package, `sudo scripts/install-host-service.sh` builds the
binary and sets up the service for whatever init system it detects (systemd,
OpenRC, runit, or s6).

## Build the firmware

Needs Docker (it pulls the ESP-IDF toolchain and a Zig with Xtensa support).

```sh
scripts/firmware.sh build
PORT=/dev/ttyUSB0 scripts/firmware.sh flash
PORT=/dev/ttyUSB0 scripts/firmware.sh monitor
```

The bridge logic is Zig (`firmware/main/bridge.zig`); C is limited to ESP-IDF
setup in `firmware/main/glue.c`. Pin assignments for the Olimex ESP32-POE are in
`firmware/main/Kconfig.projbuild`.

> On the non-ISO ESP32-POE, unplug PoE before connecting USB. Olimex warns the
> missing isolation can otherwise damage the PC.

## Repository layout

| path | what |
|---|---|
| `common/h4.zig` | HCI H4 packet framing, shared by firmware and host |
| `common/discovery.zig` | the UDP discovery protocol |
| `firmware/` | ESP32 firmware (Zig logic + ESP-IDF glue) |
| `host/` | the `hcibridge` binary: daemon, CLI, config, settings schema |
| `host/spec.zig`, `host/settings.zig` | single sources for the CLI and its settings |
| `packaging/` | nfpm config and distro recipes |
| `web/` | the browser flasher page |

## Protocol

Plain TCP carries HCI in H4 framing (one indicator byte, the HCI header, then
the payload). One client per board; a new connection replaces the old one.
Boards send `ESPHCI1 ANNOUNCE <bdaddr> <port> <name>` over UDP broadcast and
answer probes. TCP keepalive drops a dead peer in about ten seconds.

## Status

The bridge is complete and runs on real hardware: pairing, input, discovery,
per-board adapters, OTA updates, and rollback all work over 100 m of Ethernet.
Xbox Series controllers need current firmware to pair cleanly (update via a
Windows PC or an Xbox), a known BlueZ quirk rather than a bridge limitation.

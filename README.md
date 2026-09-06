# esp-hci-bridge

[![ci](https://github.com/heppu/esp-hci-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/heppu/esp-hci-bridge/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/heppu/esp-hci-bridge)](https://github.com/heppu/esp-hci-bridge/releases/latest)

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

- An **ESP32 board** (original ESP32). Ethernet with PoE is the best fit,
  but any WiFi ESP32 devkit works too. See [Supported boards](#supported-boards).
- A **Linux PC** with BlueZ and the `hci_vhci` kernel module (standard).
- Both on the **same network**.

## Get started

### 1. Flash the board

Open the **[web flasher](https://heppu.github.io/esp-hci-bridge/)** in Chrome,
Chromium, or Edge, pick your board from the dropdown, plug the board into that
computer over USB, and click Install. That is the whole firmware step.

WiFi boards with no saved network start a setup hotspot on first boot: join
`esp-hci-bridge-setup` from your phone or laptop, open `http://192.168.4.1/`,
enter your WiFi name and password. The board reboots onto your network.

(Prefer the terminal? The web flasher page lists every `.bin` for your board
with its flash offset and a ready `esptool` command. Releases carry the same
files as `esp-hci-bridge-<board>.bin`, `bootloader-<board>.bin`,
`partition-table.bin`, and `ota_data_initial.bin`.)

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

### 3. Claim the board

A fresh board talks to nobody until you claim it. Claiming pairs the board with
this PC by exchanging a key, once, over the LAN:

```sh
hcibridge list                 # find the board (KEY column says "no")
sudo hcibridge claim <ip>      # pair it with this PC
sudo rc-service hcibridged restart  # or: systemctl restart hcibridge
```

From then on the board only accepts this PC and the PC only trusts this board.
A claimed board refuses any other claim, so nobody else on the network can take
it over. To move a board to a different PC, erase it once over USB
(`esptool erase_flash`) and re-flash.

### 4. Pair your devices

```sh
bluetoothctl                   # scan / pair / connect, as with any adapter
```

Each board appears as its own controller, so its pairings stay with it.

## Managing boards

`hcibridge` is a single command. The service runs `hcibridge run`; you use the
rest by hand:

| command | what it does |
|---|---|
| `hcibridge list` | discover boards, firmware versions, whether each is claimed |
| `hcibridge claim <ip>` | pair a new board with this PC |
| `hcibridge status <ip>` | full status of one board |
| `hcibridge update <ip\|all> <file.bin>` | update firmware over the network |
| `hcibridge reboot <ip>` | reboot a board |
| `hcibridge run` | the daemon (started by the service) |

There is a man page (`man hcibridge`) and shell completions for bash, zsh, and
fish, all installed by the package.

### Updating firmware

No cable needed after the first flash. Download the new
`esp-hci-bridge-<board>.bin` for your board from a release and:

```sh
hcibridge update all esp-hci-bridge-olimex-esp32-poe.bin
```

`update all` sends that one image to every board it finds, so if you run more
than one board type, update each board by IP with its own image instead.

Boards keep two firmware slots and roll back automatically if an update fails to
come online. Updates are only accepted from the PC that claimed the board, and
only for images signed with the project's release key. Anything you flash over
USB still works, signed or not.

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
| board keys (written by `claim`) | `psk` | `--psk` | `HCIBRIDGE_PSK` |
| allow only these devices | `allow` | `--allow` | `HCIBRIDGE_ALLOW` |
| block devices | `deny` | `--deny` | `HCIBRIDGE_DENY` |

`allow`/`deny` take a board's Bluetooth address (the BDADDR from
`hcibridge list`). The installed `/etc/hcibridge/config` documents every option.

## Supported boards

Firmware ships as per-board presets (one image each, all in the web flasher and
on the release page):

| preset | board | network | status |
|---|---|---|---|
| `olimex-esp32-poe` | Olimex ESP32-POE / ESP32-POE-ISO | Ethernet, PoE | hardware-verified |
| `wt32-eth01` | Wireless-Tag WT32-ETH01 | Ethernet | built, not yet tested on hardware |
| `generic-wifi` | any ESP32 with WiFi (devkits, NodeMCU-32, etc.) | WiFi | built, not yet tested on hardware |

Ethernet is the better choice for input latency; WiFi works and is fine for
keyboards and mice, and acceptable for gamepads on a good network.

Other Ethernet boards: the PHY (LAN87xx, RTL8201, IP101, KSZ80xx, DP83848),
MDC/MDIO/power pins, PHY address, and RMII clock mode are all configurable.
Copy a preset in `firmware/boards/`, set your board's values, and build with
`BOARD=<name> scripts/firmware.sh build`. Pull requests with new presets are
welcome.

## More than one board

Discovery handles as many boards as you like at once: claim each one, and from
then on it shows up on its own when plugged in and its adapter disappears when
unplugged. Put one bridge in each room, or set `subnet` so the daemon only
listens for boards on your own network.

### Verifying downloads

Every release ships a `SHA256SUMS` file and a build provenance attestation
made by GitHub Actions, so you can check that what you downloaded is what CI
built from the tagged commit:

```sh
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify hcibridge_*_amd64.deb --repo heppu/esp-hci-bridge
```

## Security model

Everything a board does on the network is tied to a per-board key that only the
board and the PC that claimed it know:

- The TCP link carries raw HCI, so the board demands a proof of the key before
  a single Bluetooth packet flows, and the PC demands the same of the board
  before it exposes a new adapter to the kernel. An unclaimed board talks to
  nobody.
- Discovery announcements are signed with the key, so a spoofed announcement
  cannot get the daemon to attach to an attacker's machine.
- Firmware updates and reboots over HTTP need a proof of the key over the
  exact request body, and the board verifies the ECDSA signature on every image
  before it will boot it.

The key is set up by `hcibridge claim` with an X25519 exchange. Someone
watching the LAN during the claim learns nothing, but they could race you to
claim a board that is still fresh, so claim boards right after flashing. There
is no encryption on the HCI link itself. Anyone who can sniff your wired LAN
can see what the gamepad sends, which is the same exposure as a USB extender.

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
Images are signed. Without `firmware/secure_boot_signing_key.pem` the script
makes a throwaway development key, which means boards running release firmware
will reject your build over OTA (flash it over USB instead, or put the release
key in place).

```sh
scripts/firmware.sh build                              # default: olimex-esp32-poe
BOARD=generic-wifi scripts/firmware.sh build           # another preset
PORT=/dev/ttyUSB0 scripts/firmware.sh flash
PORT=/dev/ttyUSB0 scripts/firmware.sh monitor
```

Each preset builds into its own `firmware/build-<board>/`. Presets live in
`firmware/boards/*.conf`; network bring-up is in `firmware/main/net.c`.

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
| `common/auth.zig`, `firmware/main/auth.c` | the board key: handshake, signatures, claim |
| `firmware/` | ESP32 firmware (Zig logic + ESP-IDF glue) |
| `host/` | the `hcibridge` binary: daemon, CLI, config, settings schema |
| `host/spec.zig`, `host/settings.zig` | single sources for the CLI and its settings |
| `packaging/` | nfpm config and distro recipes |
| `web/` | the browser flasher page |

## Protocol

Plain TCP carries HCI in H4 framing (one indicator byte, the HCI header, then
the payload). Each connection starts with a mutual HMAC-SHA256 challenge and
response over the board key. One client per board, and a new authenticated
connection replaces the old one. Boards send
`ESPHCI1 ANNOUNCE <bdaddr> <port> <name> <sig>` over UDP broadcast and answer
probes. TCP keepalive drops a dead peer in about ten seconds.

## Status

> **Upgrading from v0.10.0 to v0.10.2?** Those releases shipped broken zsh and
> fish completions and, on rpm, a preremove script that stopped and disabled the
> service on every upgrade. After upgrading to v0.10.3 on rpm, run
> `systemctl enable --now hcibridge` once.
>
> **Upgrading from v0.9.0?** That release could not confirm an OTA-installed
> image, so boards updated *onto* v0.9.0 refuse further updates and roll back
> on reset. Power-cycle the board once (it returns to its previous firmware),
> then update to v0.9.1 or later. Boards flashed over USB are unaffected.

The bridge is complete and runs on real hardware: pairing, input, discovery,
per-board adapters, OTA updates, and rollback all work over 100 m of Ethernet.
Xbox Series controllers need current firmware to pair cleanly (update via a
Windows PC or an Xbox), a known BlueZ quirk rather than a bridge limitation.

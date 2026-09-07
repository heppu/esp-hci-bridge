# esp-hci-bridge

[![ci](https://github.com/heppu/esp-hci-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/heppu/esp-hci-bridge/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/heppu/esp-hci-bridge)](https://github.com/heppu/esp-hci-bridge/releases/latest)

A remote Bluetooth adapter for Linux. A small ESP32 board on your network
becomes a Bluetooth controller for your PC, so gamepads, keyboards, and mice
can be in a different room from the computer they control.

To Linux it is a normal Bluetooth adapter: you pair and connect with the usual
tools, and everything that works with a built-in adapter works through the
board.

```
  gamepad / keyboard / mouse
        │  Bluetooth
   ┌────┴─────┐          your network           ┌──────────────────┐
   │  ESP32   │  ─────────────────────────────▶ │  Linux PC        │
   │  board   │        Ethernet or WiFi         │  hcibridge, BlueZ│
   └──────────┘                                 └──────────────────┘
```

## What you need

- An ESP32 board. Ethernet boards give the lowest input latency, WiFi boards
  work too. See [supported boards](#supported-boards).
- A Linux PC with BlueZ. Any mainstream distro qualifies.
- Both on the same network.

## Why this and not...

**USB/IP with a Bluetooth dongle.** That needs a computer at the far end,
running Linux, `usbipd`, and a dongle. This is a 20 euro board with no
operating system, on PoE, that boots in two seconds. USB/IP also ships every
USB transaction over the network: a dongle is polled every millisecond, each
poll becomes a round trip, so inputs jitter and things like SCO audio break.
Here a button press is one Bluetooth packet, one hop. And when a USB/IP
connection drops, the dongle is unplugged as far as the kernel is concerned,
the adapter vanishes from BlueZ, and someone has to run `usbip attach` again.
Here the daemon reconnects, pairings live on the board, devices come back on
their own. USB/IP does win on radios: any dongle works, including Bluetooth
5.3 ones. The ESP32 is Bluetooth 4.2 dual mode, fine for controllers,
keyboards, mice, and headphones.

**An ESPHome Bluetooth proxy.** Different tool. That is a BLE relay for Home
Assistant: the board forwards advertisements and GATT reads, only Home
Assistant can use it, only for BLE, only through its integrations. This puts a
whole Bluetooth controller into the Linux kernel, classic and BLE, so every
program sees a normal adapter. Home Assistant on the same machine can use it
too, as a full adapter in the room where the sensors are.

**Streaming to the TV, Steam Link and friends.** That moves the video and
encodes it, with the latency and quality that brings. This keeps the PC
driving the display over a cable at full quality and only moves the
Bluetooth side to where you sit. If you already have a long HDMI run, this
completes it.

**A USB extender or a long cable for the dongle.** Works for one room on a
dedicated cable. This runs over the network you already have, through
switches, to as many rooms as you put boards in, with the PC unaware anything
is remote.

## Setup

### 1. Flash the board

Open the [web flasher](https://heppu.github.io/esp-hci-bridge/) in Chrome,
Chromium, or Edge. Pick your board, plug it in over USB, click Install.

WiFi boards start a setup hotspot on first boot. Join `esp-hci-bridge-setup`
from a phone or laptop, open `http://192.168.4.1/`, and enter your WiFi name
and password. The board reboots onto your network.

The flasher page also shows the files and offsets for `esptool` if you prefer
the terminal.

### 2. Install on the PC

Download the package for your distro from the
[latest release](https://github.com/heppu/esp-hci-bridge/releases/latest):

Every distro gets a signed package repository, so the normal upgrade command
keeps the tool current afterwards.

Debian, Ubuntu:

```sh
sudo curl -fsSLo /etc/apt/keyrings/hcibridge.gpg https://heppu.github.io/esp-hci-bridge/hcibridge.gpg
echo "deb [signed-by=/etc/apt/keyrings/hcibridge.gpg] https://heppu.github.io/esp-hci-bridge/deb stable main" | sudo tee /etc/apt/sources.list.d/hcibridge.list
sudo apt update && sudo apt install hcibridge
```

Fedora, RHEL:

```sh
sudo curl -fsSLo /etc/yum.repos.d/hcibridge.repo https://heppu.github.io/esp-hci-bridge/rpm/hcibridge.repo
sudo dnf install hcibridge
```

Alpine:

```sh
sudo wget -O /etc/apk/keys/heppu-esp-hci-bridge.rsa.pub https://heppu.github.io/esp-hci-bridge/alpine/heppu-esp-hci-bridge.rsa.pub
echo https://heppu.github.io/esp-hci-bridge/alpine | sudo tee -a /etc/apk/repositories
sudo apk add hcibridge
```

Plain package files are on the release page as well, next to a `PKGBUILD` for
Arch, an `APKBUILD` (needs Alpine edge for its Zig), and a Void template that
fetches its own Zig. Every release builds all three the way their distro does
before it is published.

Arch has a `PKGBUILD` and Void a template on the release page. The package
installs a background service that starts on boot and finds boards on its own.

### 3. Claim the board

A fresh board talks to nobody until a PC claims it. Claiming exchanges a key
once, over the network:

```sh
hcibridge list                 # find the board, KEY column says unclaimed
sudo hcibridge claim <ip>      # pair it with this PC
```

The service notices the new key on its own. A few seconds later the board
appears as a Bluetooth adapter on this PC. A claimed board refuses every other
claim, so nobody else on the network can take it.

### 4. Pair your devices

```sh
bluetoothctl                   # scan, pair, connect, as with any adapter
```

Pairings are stored on the board, so devices reconnect on their own after a
reboot of either side. Each board is its own adapter with its own pairings.

## Everyday use

You should rarely need any of this. The service handles boards coming and going
by itself.

| command | what it does |
|---|---|
| `hcibridge list` | show boards on the network, firmware version, claimed or not |
| `hcibridge status <ip>` | everything one board reports, including traffic counters |
| `sudo hcibridge claim <ip>` | pair a new board with this PC |
| `sudo hcibridge update <ip>` | update a board to the latest release over the network |
| `sudo hcibridge revoke <bdaddr>` | stop trusting a board, it is dropped at once |
| `sudo hcibridge unclaim <ip>` | release a board so another PC can claim it |
| `sudo hcibridge reboot <ip>` | reboot a board |

Commands that use a board's key need root, `list` and `status` do not. There
is a man page (`man hcibridge`) and completions for bash, zsh, and fish.

### Updating firmware

No cable needed after the first flash:

```sh
sudo hcibridge update <ip>       # one board, or `all` for every board found
```

This looks up the latest release, downloads the image for that board's type,
checks it against the release checksums, and sends it. Boards already on the
latest release are left alone. To use a specific file instead, give it as the
second argument. Boards on firmware older than v0.10.9 do not say which type
they are, so pass `--board <preset>` the first time.

Boards keep two firmware slots. If the new image fails to come up, the board
returns to the previous one by itself. Only the PC that claimed a board can
update it, and only with images signed by this project.

### Removing a board

- `sudo hcibridge revoke <bdaddr>` makes this PC stop accepting the board. The
  board keeps its key and cannot be claimed by another PC.
- `sudo hcibridge unclaim <ip>` makes the board forget its key and reboot
  fresh, and removes it here too. Use this to hand a board to another PC.
- If the PC that claimed a board is gone, erase the board over USB
  (`esptool erase_flash`) and flash it again.

### More than one board

Claim each board once. After that, plugging a board in adds an adapter and
unplugging it removes one. Put a board in every room where you want Bluetooth.

## Configuration

The defaults work for a home network. Settings live in `/etc/hcibridge/config`
with drop-ins in `/etc/hcibridge/config.d/`. Every setting can also be an
environment variable or a command line flag, and those win in that order:

```
flag  >  environment  >  config file  >  default
```

| setting | example | when to use it |
|---|---|---|
| `discovery` | `discovery = off` | you only want the boards listed under `client` |
| `subnet` | `subnet = 192.168.1.0/24` | boards should only be accepted from one network |
| `client` | `client = 192.168.1.50` | connect to a fixed address instead of discovering |
| `allow`, `deny` | `deny = aa:bb:cc:dd:ee:ff` | accept or refuse boards by Bluetooth address |

The installed config file documents every option with its flag and environment
variable name.

## Troubleshooting

**`hcibridge list` shows the board but nothing appears in `bluetoothctl`.**
Check the KEY column. An unclaimed board needs `sudo hcibridge claim <ip>`.
If it says claimed but the service still does not attach it, the board was
claimed by a different PC, or this PC's key was removed. `sudo hcibridge unclaim`
from the owning PC, or erase the board over USB, then claim again.

**`no key for ...: the key file is root-only`.** Run the command with `sudo`.

**Update says `runs firmware without ...`.** The board is on an older firmware
than the command needs. Update it first, that always works.

**A device will not pair.** Xbox controllers need current controller firmware
(update through an Xbox or the Xbox Accessories app on Windows). Otherwise
pair as you would with any adapter: `bluetoothctl`, then `scan on`, `pair`,
`trust`, `connect`.

**The board keeps rebooting after an update.** It will fall back to the previous
firmware on its own. `hcibridge status <ip>` then shows `prev_stage` (how far
the failed image got) and `reset` (why it stopped). Include both in a bug
report.

**Lag or missed inputs.** Prefer Ethernet over WiFi for gamepads. On WiFi,
keep the board close to the access point. `hcibridge status <ip>` shows drop
counters, all of which should stay at zero.

**Which service?** systemd: `hcibridge`. OpenRC and runit: `hcibridged`. Logs
go to the journal on systemd and to `/var/log/hcibridged.log` on OpenRC.

## Supported boards

| preset | board | network | status |
|---|---|---|---|
| `olimex-esp32-poe` | Olimex ESP32-POE and ESP32-POE-ISO | Ethernet, PoE | tested on hardware |
| `wt32-eth01` | Wireless-Tag WT32-ETH01 | Ethernet | builds, untested on hardware |
| `generic-wifi` | any ESP32 devkit with WiFi | WiFi | builds, untested on hardware |

Other Ethernet boards with a common PHY (LAN87xx, RTL8201, IP101, KSZ80xx,
DP83848) need only a preset file. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

> On the non-ISO Olimex ESP32-POE, unplug PoE before connecting USB. Olimex
> warns the missing isolation can damage the PC.

## Security in short

Every board has its own key, made when you claim it. Nothing happens without
that key: no Bluetooth traffic, no firmware update, no reboot. Firmware images
are signed, and the board checks the signature before booting one. The traffic
between board and PC is authenticated but not encrypted, so anyone who can
capture packets on your LAN can see what your devices send, the same as with
a USB extender.

Details in [SECURITY.md](SECURITY.md), including how to report a problem.

## Verifying downloads

Every release has a `SHA256SUMS` file and a build provenance attestation from
GitHub Actions:

```sh
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify hcibridge_*_amd64.deb --repo heppu/esp-hci-bridge
```

## Upgrade notes

- **From v0.10.0 to v0.10.2**: those packages shipped broken zsh and fish
  completions, and on rpm the service ended up stopped after an upgrade. After
  upgrading, run `sudo systemctl enable --now hcibridge` once on rpm.
- **Boards on v0.10.0 to v0.10.5**: the first update from those versions goes
  through automatically. After it the board uses a newer protocol and the PC
  must run v0.10.3 or later.
- **From v0.9.0**: boards updated onto v0.9.0 refuse further updates. Power
  cycle the board once, then update.

## For developers

Building the PC tool and the firmware, adding a board preset, the wire
protocol, and the repository layout are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Contributions are welcome, see
[CONTRIBUTING.md](CONTRIBUTING.md).

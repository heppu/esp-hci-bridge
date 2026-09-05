# esp-hci-bridge

Turns an Olimex ESP32-POE into a remote Bluetooth controller for a Linux
machine. The ESP32 runs only the Bluetooth controller (radio and link layer)
and ships raw HCI packets over TCP. The PC runs the full bluez stack against
a virtual HCI device, so pairing, HID, xpadneo, keyboards and mice all work
exactly as with a local USB dongle. The dongle just happens to be 100 m of
Ethernet away, powered by PoE.

```
 Xbox pad, keyboard, mouse
          |  Bluetooth
   +------+------+          TCP, H4 framed HCI          +-----------------+
   | ESP32-POE   | <----------------------------------> | PC              |
   | BT ctrl only|   port 4444                          | hcibridged      |
   | bridge.zig  |                                      |   -> /dev/vhci  |
   +-------------+                                      |   -> bluez      |
                                                        +-----------------+
```

## Layout

| Path | What |
|---|---|
| `common/h4.zig` | H4 packet reassembly, shared by firmware and host, allocation free |
| `firmware/main/bridge.zig` | ESP32 logic: TCP server, byte pumps, flow control, stats |
| `firmware/main/glue.c` | ESP-IDF glue: Ethernet, BT controller, sockets, FreeRTOS objects |
| `host/main.zig` | `hcibridged`, connects to the bridge and feeds `/dev/vhci` |
| `host/session.zig` | one bridge session, both directions |
| `host/sim.zig` | `hcibridge-sim`, fake controller for testing without hardware |
| `host/openrc/` | OpenRC service files |
| `scripts/firmware.sh` | builds and flashes the firmware inside the ESP-IDF container |

Everything with logic is Zig. C is limited to SDK calls that hide behind
macros or big config structs.

## Host side

Needs Zig 0.16, kernel with `hci_vhci`, bluez.

```
zig build -Doptimize=ReleaseSafe
sudo install -m 755 zig-out/bin/hcibridged /usr/local/bin/
sudo install -m 755 host/openrc/hcibridged /etc/init.d/
sudo install -m 644 host/openrc/hcibridged.confd /etc/conf.d/hcibridged
sudo rc-update add hcibridged default
sudo rc-service hcibridged start
```

Manual run:

```
sudo modprobe hci_vhci
sudo hcibridged --host 172.16.x.y --port 4444
bluetoothctl list        # new controller with the ESP32 address
```

The daemon reconnects forever. While the link is down it closes `/dev/vhci`
so bluez sees the controller go away instead of hanging on a dead one.
Pairings survive, they are keyed on the controller address.

### Without hardware

```
zig build test
zig build sim                  # fake controller on port 4444
zig build run -- --host 127.0.0.1 --once
```

The sim answers the commands bluez sends during adapter bring up and loops
ACL data back. The integration test wires daemon and sim together with a
seqpacket socket standing in for `/dev/vhci`.

## Firmware

Target board: Olimex ESP32-POE (original ESP32, LAN8710 PHY). Pins in
`firmware/main/Kconfig.projbuild`, defaults match the board:

| Signal | GPIO |
|---|---|
| MDC | 23 |
| MDIO | 18 |
| PHY power (used as reset) | 12 |
| RMII 50 MHz clock out | 17 |
| PHY address | 0 |

Build needs docker. The script pulls `espressif/idf:v5.5.5` and the
Espressif Zig fork (upstream Zig has no Xtensa backend).

```
scripts/firmware.sh build
PORT=/dev/ttyUSB0 scripts/firmware.sh flash
PORT=/dev/ttyUSB0 scripts/firmware.sh monitor
```

### Update over Ethernet

After the first USB flash every update can go over the network:

```
scripts/ota.sh 172.16.135.242                       # uses firmware/build
scripts/ota.sh 172.16.135.242 path/to/esp-hci-bridge.bin
curl http://172.16.135.242/                          # version, address, stats
```

Two OTA slots with bootloader rollback. A new image is confirmed once it
gets an IP address, otherwise the next reset boots the previous one.

### Flash from the browser

Every tag `v*` builds a release and publishes a flashing page on GitHub
Pages. Open it in Chromium, Chrome or Edge, click Install, pick the CH340
port. The page ships the exact binaries of that release, so it always flashes
the latest one. Local preview:

```
scripts/make-site.sh dev firmware/build _site
python3 -m http.server -d _site 8000     # http://localhost:8000
```

Cut a release:

```
git tag v0.1.0 && git push origin v0.1.0
```

Build without docker: have ESP-IDF 5.5 exported and `ZIG` pointing at the
Espressif Zig, then `cd firmware && idf.py build`.

The Zig part is compiled by the root `build.zig` behind `-Dfirmware=true`
and linked into the `main` component as an object. Per function sections are
on so the Xtensa linker can keep literal pools in range.

Config: `idf.py menuconfig`, menu "HCI bridge". TCP port, DHCP hostname
(`esp-hci-bridge` by default), PHY pins.

Do not connect the micro USB to a PC while the non ISO ESP32-POE is on PoE.
Olimex warns this can damage the PC. Flash with PoE unplugged, or use the
ISO board.

## Protocol

Plain TCP, one client at a time, a new connection replaces the old one. Both
directions carry H4: one indicator byte (1 command, 2 ACL, 3 SCO, 4 event, 5
ISO), the HCI header, payload. The firmware reassembles packets before handing
them to the controller because the VHCI API wants whole packets. The daemon
reassembles before writing to `/dev/vhci` for the same reason. Controller to
host bytes are forwarded as they come, TCP is a stream anyway.

Flow control: the controller says when it can take a packet, the firmware
waits up to 5 s then drops. Controller to host packets are queued in a 16 KB
FreeRTOS stream buffer, whole packets only, dropped with a counter when full
or when no host is connected.

Keepalive on both ends: 5 s idle, 2 s interval, 3 probes. A dead peer is gone
in about 11 s, then the firmware accepts a fresh connection and the daemon
reconnects once a second.

## Bring up checklist

1. Flash, open monitor. Expect `ethernet link up`, `ip ...`, `bt controller
   up, address ...`, `listening on tcp port 4444`.
2. `nc <ip> 4444` from the PC, then type nothing and close. Monitor shows
   `host connected` and `host disconnected`.
3. Start `hcibridged --host <ip>`. Monitor shows `host connected`. On the PC
   `bluetoothctl list` shows a new controller with the ESP32 address.
4. `bluetoothctl`: `select <addr>`, `power on`, `scan on`. Pair the pad.
5. Watch `stats:` lines in the monitor once a minute for drop counters.

## Status

Written blind before the board arrived. Host side is tested end to end
against the simulator. Firmware compiles and links against ESP-IDF 5.5.5 but
has not run on hardware yet. Things to look at first if it misbehaves:

- BT controller enable failing: check `CONFIG_BTDM_CTRL_MODE_BTDM` in
  `sdkconfig`, memory is tight on original ESP32 with dual mode.
- No Ethernet link: PHY power on GPIO12, it is a strapping pin on ESP32.
- Task stack overflow in `hci_rx` or `hci_tx`: bump sizes in
  `bridge_start`.

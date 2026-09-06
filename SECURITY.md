# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private
vulnerability reporting on this repository (Security tab, "Report a
vulnerability"). You should hear back within a week.

## What is covered

The threat model is documented in the README under "Security model". In short,
everything a board does on the network is authenticated with a per-board key
established by `hcibridge claim`, and firmware updates over the network are
signed with the project's release key. Reports about bypassing either of those,
or about the PC daemon feeding untrusted data into `/dev/vhci`, are very welcome.

Out of scope: physical access to the board (USB flashing is intentionally
unrestricted), and confidentiality of Bluetooth traffic on the wired LAN (the
link is authenticated but not encrypted, as documented).

## Supported versions

Only the latest release receives fixes. Boards can be updated over the network
with `hcibridge update`.

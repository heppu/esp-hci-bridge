# Contributing

Pull requests are welcome, in particular new board presets in `firmware/boards/`.

- `main` is protected. Open a pull request, CI (`host` and `firmware`) must pass,
  and the branch must be up to date before it can be merged (squash or rebase).
- Run `zig fmt` and `zig build test` before pushing. See docs/DEVELOPMENT.md for building
  the firmware in Docker.
- Keep changes focused. Board support, host daemon, and packaging changes are
  easier to review separately.
- Releases are cut by pushing a `v*` tag. Release firmware is signed with a key
  that is not in the repository, so a fork's release images will not install
  over the network on boards running upstream firmware.

//! One board's lifetime: connect to the bridge, open a private /dev/vhci,
//! pump until the link dies. Used by both the static single-board path and
//! the discovery manager.

const std = @import("std");
const Io = std.Io;
const h4 = @import("h4");
const session = @import("session.zig");

const log = std.log.scoped(.board);

pub const Error = error{VhciOpen} || anyerror;

/// Runs one connection. Returns when the link drops. Never loops; the caller
/// decides whether to retry (static mode) or wait for rediscovery (manager).
pub fn run(io: Io, addr: *const Io.net.IpAddress, vhci_path: []const u8, label: []const u8) !session.Stats {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try session.tuneSocket(stream.socket.handle);
    log.info("[{s}] connected to {f}", .{ label, addr.* });

    const vhci = Io.Dir.openFileAbsolute(io, vhci_path, .{ .mode = .read_write }) catch |err| {
        log.err("[{s}] cannot open {s}: {s} (need root and hci_vhci module)", .{ label, vhci_path, @errorName(err) });
        return error.VhciOpen;
    };
    defer vhci.close(io);
    log.info("[{s}] opened {s}, adapter attaching to bluez", .{ label, vhci_path });

    var s = session.Session.init(io, stream, .{ .file = vhci });
    const stats = try s.run();
    log.info("[{s}] link down: {d} pkts to controller, {d} to host", .{ label, stats.to_controller, stats.to_host });
    return stats;
}

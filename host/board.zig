//! One board's lifetime: connect, authenticate with the board's key, only
//! then open a private /dev/vhci and pump until the link dies.

const std = @import("std");
const Io = std.Io;
const auth = @import("auth");
const session = @import("session.zig");
const handshake = @import("handshake.zig");

const log = std.log.scoped(.board);

/// Lets the manager tear down a live link when the board reappears from a new address.
pub const Link = struct {
    mutex: Io.Mutex = .init,
    stream: ?Io.net.Stream = null,

    pub fn kill(self: *Link, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stream) |s| s.shutdown(io, .both) catch {};
    }

    fn set(self: *Link, io: Io, stream: ?Io.net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stream = stream;
    }
};

/// Runs one authenticated connection. Returns when the link drops. Never
/// loops; the caller retries (static mode) or waits for rediscovery.
pub fn run(io: Io, addr: *const Io.net.IpAddress, vhci_path: []const u8, label: []const u8, psk: *const auth.Psk, link: ?*Link) !session.Stats {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try session.tuneSocket(stream.socket.handle);
    log.info("[{s}] connected to {f}, authenticating", .{ label, addr.* });

    handshake.client(io, stream, psk) catch |err| switch (err) {
        error.HandshakeTimeout => {
            log.warn("[{s}] board did not answer the handshake in time", .{label});
            return error.HandshakeTimeout;
        },
        else => {
            log.err("[{s}] authentication failed: {s} (wrong key, or not the real board)", .{ label, @errorName(err) });
            return error.AuthFailed;
        },
    };
    log.info("[{s}] authenticated", .{label});
    if (link) |l| l.set(io, stream);
    defer if (link) |l| l.set(io, null);

    // The kernel only sees this peer after it proved it holds the key.
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

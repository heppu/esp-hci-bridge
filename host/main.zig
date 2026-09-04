//! hcibridged: attaches a remote ESP32 Bluetooth controller to the local
//! kernel Bluetooth stack.
//!
//! TCP side carries raw HCI packets in H4 framing. Local side is /dev/vhci,
//! where every read returns one packet and every write must be one packet.
//! The daemon reconnects forever, and drops the vhci device while the link
//! is down so bluez sees the controller disappear instead of hanging.

const std = @import("std");
const Io = std.Io;
const h4 = @import("h4");
const session = @import("session.zig");

const log = std.log;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Options = struct {
    host: []const u8 = "esp-hci-bridge",
    port: u16 = 4444,
    vhci_path: []const u8 = "/dev/vhci",
    reconnect_ms: u32 = 1000,
    once: bool = false,
};

const usage =
    \\usage: hcibridged [options]
    \\
    \\  --host <name|ip>     bridge address (default esp-hci-bridge)
    \\  --port <n>           bridge TCP port (default 4444)
    \\  --vhci <path>        virtual HCI device (default /dev/vhci)
    \\  --reconnect-ms <n>   delay between connection attempts (default 1000)
    \\  --once               exit after the first session ends
    \\  -h, --help           this text
    \\
;

fn parseArgs(args: std.process.Args) !Options {
    var opts: Options = .{};
    var it = args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            opts.host = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--port")) {
            opts.port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--vhci")) {
            opts.vhci_path = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--reconnect-ms")) {
            opts.reconnect_ms = try std.fmt.parseInt(u32, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--once")) {
            opts.once = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.Help;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.BadArgument;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const opts = parseArgs(init.minimal.args) catch |err| switch (err) {
        error.Help => {
            try Io.File.stderr().writeStreamingAll(io, usage);
            return 0;
        },
        else => {
            try Io.File.stderr().writeStreamingAll(io, usage);
            return 2;
        },
    };

    log.info("hcibridged starting, bridge {s}:{d}, vhci {s}", .{ opts.host, opts.port, opts.vhci_path });

    while (true) {
        runOnce(io, opts) catch |err| {
            log.warn("session ended: {s}", .{@errorName(err)});
        };
        if (opts.once) return 0;
        try io.sleep(Io.Duration.fromMilliseconds(opts.reconnect_ms), .awake);
    }
}

fn runOnce(io: Io, opts: Options) !void {
    const addr = try Io.net.IpAddress.resolve(io, opts.host, opts.port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try session.tuneSocket(stream.socket.handle);
    log.info("connected to {f}", .{addr});

    const vhci = try Io.Dir.openFileAbsolute(io, opts.vhci_path, .{ .mode = .read_write });
    defer vhci.close(io);
    log.info("opened {s}", .{opts.vhci_path});

    var s = session.Session.init(io, stream, .{ .file = vhci });
    const stats = try s.run();
    log.info("link down after {d} packets to controller, {d} packets to host", .{ stats.to_controller, stats.to_host });
}

test {
    _ = session;
}

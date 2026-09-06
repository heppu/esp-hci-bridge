//! hcibridged: attaches remote ESP32 Bluetooth controllers to the local
//! kernel Bluetooth stack.
//!
//! Default (manager) mode discovers bridges on the LAN by UDP broadcast and
//! gives each its own vhci adapter, plug and play. Passing --host pins a
//! single board and skips discovery.

const std = @import("std");
const Io = std.Io;
const board = @import("board.zig");
const manager = @import("manager.zig");
const disc = @import("discovery");

const log = std.log;

pub const std_options: std.Options = .{ .log_level = .info };

const Options = struct {
    host: ?[]const u8 = null,
    port: u16 = 4444,
    vhci_path: []const u8 = "/dev/vhci",
    discovery_port: u16 = disc.default_port,
    reconnect_ms: u32 = 1000,
    once: bool = false,
};

const usage =
    \\usage: hcibridged [options]
    \\
    \\  (no --host)          discover bridges on the LAN, one adapter each
    \\  --host <name|ip>     pin a single bridge, skip discovery
    \\  --port <n>           bridge TCP port for --host (default 4444)
    \\  --vhci <path>        virtual HCI device (default /dev/vhci)
    \\  --discovery-port <n> UDP discovery port (default 4445)
    \\  --reconnect-ms <n>   retry delay in --host mode (default 1000)
    \\  --once               --host mode: exit after the first session
    \\  -h, --help           this text
    \\
;

fn parseArgs(args: std.process.Args) !Options {
    var o: Options = .{};
    var it = args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--host")) {
            o.host = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--port")) {
            o.port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--vhci")) {
            o.vhci_path = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--discovery-port")) {
            o.discovery_port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--reconnect-ms")) {
            o.reconnect_ms = try std.fmt.parseInt(u32, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--once")) {
            o.once = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.Help;
        } else {
            log.err("unknown argument: {s}", .{a});
            return error.BadArgument;
        }
    }
    return o;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
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

    if (opts.host) |host| return staticMode(io, host, opts);

    log.info("hcibridged starting in discovery mode", .{});
    try manager.run(io, gpa, .{ .discovery_port = opts.discovery_port, .vhci_path = opts.vhci_path });
    return 0;
}

fn staticMode(io: Io, host: []const u8, opts: Options) !u8 {
    log.info("hcibridged starting, pinned to {s}:{d}", .{ host, opts.port });
    while (true) {
        const addr = Io.net.IpAddress.resolve(io, host, opts.port) catch |err| {
            log.warn("resolve {s}: {s}", .{ host, @errorName(err) });
            try io.sleep(Io.Duration.fromMilliseconds(opts.reconnect_ms), .awake);
            continue;
        };
        _ = board.run(io, &addr, opts.vhci_path, host) catch |err| {
            log.warn("session ended: {s}", .{@errorName(err)});
        };
        if (opts.once) return 0;
        try io.sleep(Io.Duration.fromMilliseconds(opts.reconnect_ms), .awake);
    }
}

test {
    _ = @import("session.zig");
    _ = @import("board.zig");
    _ = @import("manager.zig");
}

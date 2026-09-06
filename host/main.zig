//! hcibridge: one binary, several jobs.
//!
//!   hcibridge run [opts]        daemon (default if no subcommand)
//!   hcibridge list              discover bridges and show firmware versions
//!   hcibridge status <ip>       full JSON status of one bridge
//!   hcibridge update <ip|all> <file.bin>   push an OTA update
//!
//! run mode discovers bridges on the LAN and gives each its own vhci adapter,
//! or pins one with --host.

const std = @import("std");
const Io = std.Io;
const board = @import("board.zig");
const manager = @import("manager.zig");
const cli = @import("cli.zig");
const disc = @import("discovery");

const log = std.log;

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage: hcibridge <command> [options]
    \\
    \\commands:
    \\  run                       daemon: attach bridges to the local BT stack (default)
    \\  list                      discover bridges and print their firmware versions
    \\  status <ip>               print one bridge's full status
    \\  update <ip|all> <file>    push a firmware image over OTA
    \\
    \\run options:
    \\  (none)                    discover all bridges, one adapter each
    \\  --host <name|ip>          pin a single bridge, skip discovery
    \\  --port <n>                bridge TCP port for --host (default 4444)
    \\  --vhci <path>             virtual HCI device (default /dev/vhci)
    \\  --discovery-port <n>      UDP discovery port (default 4445)
    \\  --reconnect-ms <n>        retry delay in --host mode (default 1000)
    \\  --once                    --host mode: exit after the first session
    \\
    \\list/update options:
    \\  --discovery-port <n>      UDP discovery port (default 4445)
    \\
;

const RunOpts = struct {
    host: ?[]const u8 = null,
    port: u16 = 4444,
    vhci_path: []const u8 = "/dev/vhci",
    discovery_port: u16 = disc.default_port,
    reconnect_ms: u32 = 1000,
    once: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var it = init.minimal.args.iterate();
    _ = it.next();

    const cmd = it.next() orelse "run";

    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        var dport: u16 = disc.default_port;
        while (it.next()) |a| if (std.mem.eql(u8, a, "--discovery-port")) {
            dport = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        };
        return cli.list(io, gpa, dport, 2500);
    }
    if (std.mem.eql(u8, cmd, "status")) {
        const ip = it.next() orelse {
            log.err("usage: hcibridge status <ip>", .{});
            return 2;
        };
        return cli.status(io, gpa, ip);
    }
    if (std.mem.eql(u8, cmd, "update")) {
        const target = it.next() orelse {
            log.err("usage: hcibridge update <ip|all> <file.bin>", .{});
            return 2;
        };
        const file = it.next() orelse {
            log.err("usage: hcibridge update <ip|all> <file.bin>", .{});
            return 2;
        };
        var dport: u16 = disc.default_port;
        while (it.next()) |a| if (std.mem.eql(u8, a, "--discovery-port")) {
            dport = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        };
        return cli.update(io, gpa, target, file, dport);
    }
    if (!std.mem.eql(u8, cmd, "run")) {
        // Back-compat: `hcibridge --host x ...` with no subcommand.
        if (std.mem.startsWith(u8, cmd, "-")) {
            var o = RunOpts{};
            try parseRun(&o, cmd, &it);
            while (it.next()) |a| try parseRun(&o, a, &it);
            return runMode(io, gpa, o);
        }
        log.err("unknown command: {s}", .{cmd});
        try Io.File.stderr().writeStreamingAll(io, usage);
        return 2;
    }

    var o = RunOpts{};
    while (it.next()) |a| try parseRun(&o, a, &it);
    return runMode(io, gpa, o);
}

fn parseRun(o: *RunOpts, a: []const u8, it: *std.process.Args.Iterator) !void {
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
    } else {
        return error.BadArgument;
    }
}

fn runMode(io: Io, gpa: std.mem.Allocator, o: RunOpts) !u8 {
    if (o.host) |host| {
        log.info("hcibridge run, pinned to {s}:{d}", .{ host, o.port });
        while (true) {
            const addr = Io.net.IpAddress.resolve(io, host, o.port) catch |err| {
                log.warn("resolve {s}: {s}", .{ host, @errorName(err) });
                try io.sleep(Io.Duration.fromMilliseconds(o.reconnect_ms), .awake);
                continue;
            };
            _ = board.run(io, &addr, o.vhci_path, host) catch |err| {
                log.warn("session ended: {s}", .{@errorName(err)});
            };
            if (o.once) return 0;
            try io.sleep(Io.Duration.fromMilliseconds(o.reconnect_ms), .awake);
        }
    }
    log.info("hcibridge run, discovery mode", .{});
    try manager.run(io, gpa, .{ .discovery_port = o.discovery_port, .vhci_path = o.vhci_path });
    return 0;
}

test {
    _ = @import("session.zig");
    _ = @import("board.zig");
    _ = @import("manager.zig");
    _ = @import("httpc.zig");
    _ = @import("cli.zig");
}

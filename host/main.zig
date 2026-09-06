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
const spec = @import("spec.zig");
const config = @import("config.zig");
const settings = @import("settings.zig");
const auth = @import("auth");

const log = std.log;

pub const std_options: std.Options = .{ .log_level = .info };

fn printHelp(io: Io, file: Io.File) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try spec.writeHelp(&w.interface);
    try w.interface.flush();
}

fn emit(io: Io, gen: *const fn (*Io.Writer) anyerror!void) !u8 {
    var buf: [8192]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try gen(&w.interface);
    try w.interface.flush();
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var it = init.minimal.args.iterate();
    _ = it.next();

    const cmd = it.next() orelse "run";

    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try printHelp(io, Io.File.stdout());
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        var buf: [64]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        try w.interface.print("{s} {s}\n", .{ spec.program, spec.version });
        try w.interface.flush();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "man")) return emit(io, spec.writeMan);
    if (std.mem.eql(u8, cmd, "completions")) {
        const shell = it.next() orelse {
            log.err("usage: hcibridge completions <bash|zsh|fish>", .{});
            return 2;
        };
        var buf: [8192]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        spec.writeCompletion(&w.interface, shell) catch |err| switch (err) {
            error.UnknownShell => {
                log.err("unknown shell: {s} (want bash, zsh or fish)", .{shell});
                return 2;
            },
            else => return err,
        };
        try w.interface.flush();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        var dport: u16 = disc.default_port;
        while (it.next()) |a| if (std.mem.eql(u8, a, "--discovery-port")) {
            dport = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        };
        return cli.list(io, gpa, dport, 2500);
    }
    if (std.mem.eql(u8, cmd, "claim")) {
        const ip = it.next() orelse {
            log.err("usage: hcibridge claim <ip> [--config <path>]", .{});
            return 2;
        };
        var cfg: []const u8 = cli.default_config;
        while (it.next()) |a| if (std.mem.eql(u8, a, "--config")) {
            cfg = it.next() orelse return error.MissingValue;
        };
        return cli.claim(io, gpa, ip, cfg);
    }
    if (std.mem.eql(u8, cmd, "reboot")) {
        const ip = it.next() orelse {
            log.err("usage: hcibridge reboot <ip> [--config <path>]", .{});
            return 2;
        };
        var cfg: []const u8 = cli.default_config;
        while (it.next()) |a| if (std.mem.eql(u8, a, "--config")) {
            cfg = it.next() orelse return error.MissingValue;
        };
        return cli.reboot(io, gpa, ip, cfg);
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
        var cfg: []const u8 = cli.default_config;
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--discovery-port")) {
                dport = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
            } else if (std.mem.eql(u8, a, "--config")) {
                cfg = it.next() orelse return error.MissingValue;
            }
        }
        return cli.update(io, gpa, target, file, dport, cfg);
    }
    if (!std.mem.eql(u8, cmd, "run")) {
        // Back-compat: `hcibridge --host x ...` with no subcommand.
        if (std.mem.startsWith(u8, cmd, "-")) {
            var rest: std.ArrayList([]const u8) = .empty;
            defer rest.deinit(gpa);
            try rest.append(gpa, cmd);
            while (it.next()) |a| try rest.append(gpa, a);
            return runMode(io, gpa, rest.items, init.environ_map);
        }
        log.err("unknown command: {s}", .{cmd});
        try printHelp(io, Io.File.stderr());
        return 2;
    }

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    while (it.next()) |a| try rest.append(gpa, a);
    return runMode(io, gpa, rest.items, init.environ_map);
}

fn envGet(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
    const map: *std.process.Environ.Map = @ptrCast(@alignCast(ctx.?));
    return map.get(name);
}

const ClientCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
    vhci: []const u8,
    reconnect_ms: u32,
    psk: auth.Psk,
};

fn clientThread(ctx: *ClientCtx) void {
    while (true) {
        const addr = Io.net.IpAddress.resolve(ctx.io, ctx.host, ctx.port) catch |err| {
            log.warn("resolve {s}: {s}", .{ ctx.host, @errorName(err) });
            ctx.io.sleep(Io.Duration.fromMilliseconds(ctx.reconnect_ms), .awake) catch {};
            continue;
        };
        _ = board.run(ctx.io, &addr, ctx.vhci, ctx.host, &ctx.psk) catch |err| {
            log.warn("[{s}] session ended: {s}", .{ ctx.host, @errorName(err) });
        };
        ctx.io.sleep(Io.Duration.fromMilliseconds(ctx.reconnect_ms), .awake) catch {};
    }
}

fn splitHostPort(client: []const u8, default_port: u16) struct { host: []const u8, port: u16 } {
    if (std.mem.lastIndexOfScalar(u8, client, ':')) |c| {
        if (std.fmt.parseInt(u16, client[c + 1 ..], 10)) |p| {
            return .{ .host = client[0..c], .port = p };
        } else |_| {}
    }
    return .{ .host = client, .port = default_port };
}

fn runMode(io: Io, gpa: std.mem.Allocator, args: []const []const u8, env_map: *std.process.Environ.Map) !u8 {
    // Config path can be overridden with --config; default is well-known.
    var cfg_path: []const u8 = "/etc/hcibridge/config";
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        if (std.mem.eql(u8, args[k], "--config")) {
            k += 1;
            if (k >= args.len) return error.MissingValue;
            cfg_path = args[k];
        }
    }
    // Strip --config from the args handed to the resolver.
    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(gpa);
    var m: usize = 0;
    while (m < args.len) : (m += 1) {
        if (std.mem.eql(u8, args[m], "--config")) {
            m += 1;
            continue;
        }
        try filtered.append(gpa, args[m]);
    }

    var raw = config.loadRaw(gpa, io, cfg_path) catch |err| blk: {
        log.warn("config {s}: {s} (using defaults)", .{ cfg_path, @errorName(err) });
        break :blk config.Raw{ .arena = std.heap.ArenaAllocator.init(gpa) };
    };
    defer raw.deinit();

    var s = settings.resolve(gpa, raw.pairs.items, filtered.items, envGet, @ptrCast(env_map)) catch |err| {
        log.err("bad settings: {s}", .{@errorName(err)});
        return 2;
    };
    defer s.deinit();

    if (s.clients.len == 0 and !s.discovery) {
        log.err("nothing to do: discovery is off and no clients configured", .{});
        return 2;
    }

    // Pinned client boards each get their own reconnecting thread. A pinned
    // board is matched to a key by its address ("psk = <ip>=<hex>" works too),
    // or by the only key when there is exactly one.
    for (s.clients) |client| {
        const hp = splitHostPort(client, s.port);
        const psk = settings.lookupPsk(s.psk, hp.host) orelse
            (if (s.psk.len == 1) settings.lookupPsk(s.psk, s.psk[0][0 .. std.mem.indexOfScalar(u8, s.psk[0], '=') orelse 0]) else null) orelse {
            log.err("no key for pinned board {s}: run `hcibridge claim {s}`", .{ hp.host, hp.host });
            return 2;
        };
        const ctx = try gpa.create(ClientCtx);
        ctx.* = .{ .io = io, .gpa = gpa, .host = hp.host, .port = hp.port, .vhci = s.vhci, .reconnect_ms = s.reconnect_ms, .psk = psk };
        if (s.once and s.clients.len == 1 and !s.discovery) {
            // one-shot for scripting/tests
            const addr = try Io.net.IpAddress.resolve(io, hp.host, hp.port);
            _ = board.run(io, &addr, s.vhci, hp.host, &psk) catch {};
            return 0;
        }
        const t = try std.Thread.spawn(.{}, clientThread, .{ctx});
        t.detach();
        log.info("pinned board {s}:{d}", .{ hp.host, hp.port });
    }

    if (s.discovery) {
        log.info("hcibridge run, discovery on ({s}:{d})", .{ s.bind, s.discovery_port });
        try manager.run(io, gpa, .{
            .discovery_port = s.discovery_port,
            .vhci_path = s.vhci,
            .bind = s.bind,
            .subnet = s.subnet,
            .allow = s.allow,
            .deny = s.deny,
            .psk_entries = s.psk,
        });
        return 0;
    }

    // Discovery off but clients running in threads: park forever.
    log.info("hcibridge run, {d} pinned board(s), discovery off", .{s.clients.len});
    while (true) try io.sleep(Io.Duration.fromMilliseconds(3600_000), .awake);
}

test {
    _ = @import("session.zig");
    _ = @import("board.zig");
    _ = @import("manager.zig");
    _ = @import("httpc.zig");
    _ = @import("cli.zig");
    _ = @import("spec.zig");
    _ = @import("config.zig");
    _ = @import("settings.zig");
    _ = @import("handshake.zig");
}

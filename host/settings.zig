//! Single source of truth for daemon settings. One schema drives the config
//! file keys, environment variables, and CLI flags, resolved with precedence
//!
//!     flag  >  env  >  config file (+ .d)  >  built-in default
//!
//! Scalars take the highest-precedence value; lists (clients, allow, deny)
//! accumulate across all sources.

const std = @import("std");
const config = @import("config.zig");

const log = std.log.scoped(.settings);

pub const Kind = enum { str, port, u32v, boolean, list };

pub const Desc = struct {
    /// Settings field name (must match a field below).
    field: []const u8,
    flag: []const u8,
    env: []const u8,
    key: []const u8,
    kind: Kind,
    arg: ?[]const u8 = null,
    help: []const u8,
};

/// The schema. Everything downstream is generated from this.
pub const descs = [_]Desc{
    .{ .field = "discovery", .flag = "--discovery", .env = "HCIBRIDGE_DISCOVERY", .key = "discovery", .kind = .boolean, .arg = "on|off", .help = "auto-discover bridges on the LAN (default on; --no-discovery to disable)" },
    .{ .field = "bind", .flag = "--bind", .env = "HCIBRIDGE_BIND", .key = "bind", .kind = .str, .arg = "ip", .help = "address to listen on for discovery (default 0.0.0.0)" },
    .{ .field = "subnet", .flag = "--subnet", .env = "HCIBRIDGE_SUBNET", .key = "subnet", .kind = .str, .arg = "cidr", .help = "only attach boards whose IP is in this range, e.g. 172.16.0.0/16" },
    .{ .field = "discovery_port", .flag = "--discovery-port", .env = "HCIBRIDGE_DISCOVERY_PORT", .key = "discovery-port", .kind = .port, .arg = "n", .help = "UDP discovery port (default 4445)" },
    .{ .field = "port", .flag = "--port", .env = "HCIBRIDGE_PORT", .key = "port", .kind = .port, .arg = "n", .help = "default board TCP port (default 4444)" },
    .{ .field = "vhci", .flag = "--vhci", .env = "HCIBRIDGE_VHCI", .key = "vhci", .kind = .str, .arg = "path", .help = "virtual HCI device (default /dev/vhci)" },
    .{ .field = "reconnect_ms", .flag = "--reconnect-ms", .env = "HCIBRIDGE_RECONNECT_MS", .key = "reconnect-ms", .kind = .u32v, .arg = "n", .help = "reconnect delay for pinned boards (default 1000)" },
    .{ .field = "clients", .flag = "--client", .env = "HCIBRIDGE_CLIENTS", .key = "client", .kind = .list, .arg = "ip", .help = "static ESP board to attach (repeatable); disables the need for discovery" },
    .{ .field = "allow", .flag = "--allow", .env = "HCIBRIDGE_ALLOW", .key = "allow", .kind = .list, .arg = "bdaddr", .help = "only attach boards with these Bluetooth addresses (repeatable)" },
    .{ .field = "deny", .flag = "--deny", .env = "HCIBRIDGE_DENY", .key = "deny", .kind = .list, .arg = "bdaddr", .help = "never attach boards with these Bluetooth addresses (repeatable)" },
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    discovery: bool = true,
    bind: []const u8 = "0.0.0.0",
    subnet: []const u8 = "",
    discovery_port: u16 = 4445,
    port: u16 = 4444,
    vhci: []const u8 = "/dev/vhci",
    reconnect_ms: u32 = 1000,
    clients: []const []const u8 = &.{},
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    once: bool = false,

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }
};

pub const EnvGet = *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8;

fn descByFlag(flag: []const u8) ?Desc {
    for (descs) |d| if (std.mem.eql(u8, d.flag, flag)) return d;
    return null;
}

fn parseBool(v: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes") or std.mem.eql(u8, v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "no") or std.mem.eql(u8, v, "0")) return false;
    return null;
}

/// Resolves settings from config pairs, environment, and CLI args.
/// `args` are the run-mode arguments (after the `run` subcommand).
pub fn resolve(
    gpa: std.mem.Allocator,
    conf_pairs: []const config.Pair,
    args: []const []const u8,
    env_get: ?EnvGet,
    env_ctx: ?*anyopaque,
) !Settings {
    var s: Settings = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer s.deinit();
    const a = s.arena.allocator();

    // Build one ordered list of field/value pairs: conf, then env, then flags.
    // Scalars resolve to the last matching entry (so flags win); lists take all.
    var layered: std.ArrayList(config.Pair) = .empty;
    defer layered.deinit(gpa);

    // conf: map file keys -> field names
    for (conf_pairs) |p| {
        for (descs) |d| {
            if (std.mem.eql(u8, d.key, p.key)) {
                try layered.append(gpa, .{ .key = d.field, .value = p.value });
            }
        }
    }
    // env
    if (env_get) |get| {
        for (descs) |d| {
            if (get(env_ctx, d.env)) |v| {
                if (d.kind == .list) {
                    var it = std.mem.splitScalar(u8, v, ',');
                    while (it.next()) |item| {
                        const t = std.mem.trim(u8, item, " ");
                        if (t.len > 0) try layered.append(gpa, .{ .key = d.field, .value = t });
                    }
                } else {
                    try layered.append(gpa, .{ .key = d.field, .value = v });
                }
            }
        }
    }
    // flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--once")) {
            s.once = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            // sugar: pin one board and turn discovery off
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try layered.append(gpa, .{ .key = "clients", .value = args[i] });
            try layered.append(gpa, .{ .key = "discovery", .value = "off" });
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-discovery")) {
            try layered.append(gpa, .{ .key = "discovery", .value = "off" });
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const d = descByFlag(arg) orelse return error.BadArgument;
            if (d.kind == .boolean) {
                // optional value; bare flag means on
                if (i + 1 < args.len and parseBool(args[i + 1]) != null) {
                    i += 1;
                    try layered.append(gpa, .{ .key = d.field, .value = args[i] });
                } else {
                    try layered.append(gpa, .{ .key = d.field, .value = "on" });
                }
            } else {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                try layered.append(gpa, .{ .key = d.field, .value = args[i] });
            }
            continue;
        }
        return error.BadArgument;
    }

    // Resolve each field from the layered list.
    var clients: std.ArrayList([]const u8) = .empty;
    var allow: std.ArrayList([]const u8) = .empty;
    var deny: std.ArrayList([]const u8) = .empty;

    for (layered.items) |p| {
        if (std.mem.eql(u8, p.key, "discovery")) {
            s.discovery = parseBool(p.value) orelse s.discovery;
        } else if (std.mem.eql(u8, p.key, "bind")) {
            s.bind = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.key, "subnet")) {
            s.subnet = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.key, "discovery_port")) {
            s.discovery_port = std.fmt.parseInt(u16, p.value, 10) catch s.discovery_port;
        } else if (std.mem.eql(u8, p.key, "port")) {
            s.port = std.fmt.parseInt(u16, p.value, 10) catch s.port;
        } else if (std.mem.eql(u8, p.key, "vhci")) {
            s.vhci = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.key, "reconnect_ms")) {
            s.reconnect_ms = std.fmt.parseInt(u32, p.value, 10) catch s.reconnect_ms;
        } else if (std.mem.eql(u8, p.key, "clients")) {
            try clients.append(a, try a.dupe(u8, p.value));
        } else if (std.mem.eql(u8, p.key, "allow")) {
            try allow.append(a, try a.dupe(u8, p.value));
        } else if (std.mem.eql(u8, p.key, "deny")) {
            try deny.append(a, try a.dupe(u8, p.value));
        }
    }
    s.clients = try clients.toOwnedSlice(a);
    s.allow = try allow.toOwnedSlice(a);
    s.deny = try deny.toOwnedSlice(a);
    return s;
}

/// Renders the run options for help/man, from the schema.
pub fn writeOptions(w: *std.Io.Writer) !void {
    for (descs) |d| {
        const head = if (d.arg) |ar| blk: {
            var buf: [48]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{s} <{s}>", .{ d.flag, ar }) catch d.flag;
        } else d.flag;
        try w.print("  {s}", .{head});
        var pad: usize = if (head.len < 26) 26 - head.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}  [env {s}]\n", .{ d.help, d.env });
    }
    try w.writeAll("  --host <addr>              pin one board and disable discovery (sugar)\n");
    try w.writeAll("  --config <path>            config file (default /etc/hcibridge/config; .d drop-ins)\n");
}

const testing = std.testing;

fn envNone(_: ?*anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

const TestEnv = struct {
    var pairs: []const [2][]const u8 = &.{};
    fn get(_: ?*anyopaque, name: []const u8) ?[]const u8 {
        for (pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "defaults" {
    var s = try resolve(testing.allocator, &.{}, &.{}, null, null);
    defer s.deinit();
    try testing.expect(s.discovery);
    try testing.expectEqual(@as(u16, 4445), s.discovery_port);
    try testing.expectEqualStrings("0.0.0.0", s.bind);
}

test "flag beats env beats conf" {
    const conf = [_]config.Pair{.{ .key = "discovery-port", .value = "1111" }};
    TestEnv.pairs = &.{.{ "HCIBRIDGE_DISCOVERY_PORT", "2222" }};
    // conf only
    var s1 = try resolve(testing.allocator, &conf, &.{}, null, null);
    defer s1.deinit();
    try testing.expectEqual(@as(u16, 1111), s1.discovery_port);
    // env overrides conf
    var s2 = try resolve(testing.allocator, &conf, &.{}, TestEnv.get, null);
    defer s2.deinit();
    try testing.expectEqual(@as(u16, 2222), s2.discovery_port);
    // flag overrides env
    var s3 = try resolve(testing.allocator, &conf, &.{ "--discovery-port", "3333" }, TestEnv.get, null);
    defer s3.deinit();
    try testing.expectEqual(@as(u16, 3333), s3.discovery_port);
    TestEnv.pairs = &.{};
}

test "lists accumulate across sources" {
    const conf = [_]config.Pair{.{ .key = "client", .value = "10.0.0.1" }};
    TestEnv.pairs = &.{.{ "HCIBRIDGE_CLIENTS", "10.0.0.2,10.0.0.3" }};
    var s = try resolve(testing.allocator, &conf, &.{ "--client", "10.0.0.4" }, TestEnv.get, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 4), s.clients.len);
    TestEnv.pairs = &.{};
}

test "no-discovery and host sugar" {
    var s = try resolve(testing.allocator, &.{}, &.{ "--host", "1.2.3.4" }, null, null);
    defer s.deinit();
    try testing.expect(!s.discovery);
    try testing.expectEqual(@as(usize, 1), s.clients.len);
    try testing.expectEqualStrings("1.2.3.4", s.clients[0]);

    var s2 = try resolve(testing.allocator, &.{}, &.{"--no-discovery"}, null, null);
    defer s2.deinit();
    try testing.expect(!s2.discovery);
}

test "boolean explicit value" {
    var s = try resolve(testing.allocator, &.{}, &.{ "--discovery", "off" }, null, null);
    defer s.deinit();
    try testing.expect(!s.discovery);
}

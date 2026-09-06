//! Single source of truth for daemon settings. One schema drives the config
//! file keys, environment variables, and CLI flags, resolved with precedence
//!
//!     flag  >  env  >  config file (+ .d)  >  built-in default
//!
//! Scalars take the highest-precedence value; lists (clients, allow, deny)
//! accumulate across all sources.

const std = @import("std");
const config = @import("config.zig");
const auth = @import("auth");

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
    .{ .field = "discovery", .flag = "--discovery", .env = "HCIBRIDGE_DISCOVERY", .key = "discovery", .kind = .boolean, .arg = "on|off", .help = "auto-discover bridges on the LAN (default on, --no-discovery turns it off)" },
    .{ .field = "bind", .flag = "--bind", .env = "HCIBRIDGE_BIND", .key = "bind", .kind = .str, .arg = "ip", .help = "address to listen on for discovery (default 0.0.0.0)" },
    .{ .field = "subnet", .flag = "--subnet", .env = "HCIBRIDGE_SUBNET", .key = "subnet", .kind = .str, .arg = "cidr", .help = "only attach boards whose IP is in this range, e.g. 172.16.0.0/16" },
    .{ .field = "discovery_port", .flag = "--discovery-port", .env = "HCIBRIDGE_DISCOVERY_PORT", .key = "discovery-port", .kind = .port, .arg = "n", .help = "UDP discovery port (default 4445)" },
    .{ .field = "port", .flag = "--port", .env = "HCIBRIDGE_PORT", .key = "port", .kind = .port, .arg = "n", .help = "default board TCP port (default 4444)" },
    .{ .field = "vhci", .flag = "--vhci", .env = "HCIBRIDGE_VHCI", .key = "vhci", .kind = .str, .arg = "path", .help = "virtual HCI device (default /dev/vhci)" },
    .{ .field = "reconnect_ms", .flag = "--reconnect-ms", .env = "HCIBRIDGE_RECONNECT_MS", .key = "reconnect-ms", .kind = .u32v, .arg = "n", .help = "reconnect delay for pinned boards (default 1000)" },
    .{ .field = "clients", .flag = "--client", .env = "HCIBRIDGE_CLIENTS", .key = "client", .kind = .list, .arg = "ip", .help = "static ESP board to attach (repeatable), removes the need for discovery" },
    .{ .field = "allow", .flag = "--allow", .env = "HCIBRIDGE_ALLOW", .key = "allow", .kind = .list, .arg = "bdaddr", .help = "only attach boards with these Bluetooth addresses (repeatable)" },
    .{ .field = "deny", .flag = "--deny", .env = "HCIBRIDGE_DENY", .key = "deny", .kind = .list, .arg = "bdaddr", .help = "never attach boards with these Bluetooth addresses (repeatable)" },
    .{ .field = "psk", .flag = "--psk", .env = "HCIBRIDGE_PSK", .key = "psk", .kind = .list, .arg = "bdaddr=hex", .help = "board key from hcibridge claim (repeatable), only keyed boards are attached" },
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
    psk: []const []const u8 = &.{},
    once: bool = false,

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }
};

/// Finds the PSK for a board among "bdaddr=hex" entries (bdaddr case-insensitive).
/// Entries are ordered by precedence, so the last valid match wins.
pub fn lookupPsk(entries: []const []const u8, bdaddr: []const u8) ?auth.Psk {
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, e[0..eq], " "), bdaddr)) continue;
        if (auth.hexToPsk(std.mem.trim(u8, e[eq + 1 ..], " "))) |p| return p;
        log.warn("ignoring malformed psk entry for {s} (want 64 hex chars)", .{bdaddr});
    }
    return null;
}

pub const EnvGet = *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8;

/// One value on its way into a Settings field, with where it came from for diagnostics.
const Layer = struct {
    field: []const u8,
    name: []const u8,
    value: []const u8,
    src: []const u8,
};

fn descByFlag(flag: []const u8) ?Desc {
    for (descs) |d| if (std.mem.eql(u8, d.flag, flag)) return d;
    return null;
}

fn descByKey(key: []const u8) ?Desc {
    for (descs) |d| if (std.mem.eql(u8, d.key, key)) return d;
    return null;
}

fn parseIntOr(comptime T: type, l: Layer, fallback: T) T {
    return std.fmt.parseInt(T, l.value, 10) catch {
        log.warn("{s}: ignoring {s} = {s} (want a number 0..{d})", .{ l.src, l.name, l.value, std.math.maxInt(T) });
        return fallback;
    };
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
    var layered: std.ArrayList(Layer) = .empty;
    defer layered.deinit(gpa);

    // conf: map file keys -> field names
    for (conf_pairs) |p| {
        const d = descByKey(p.key) orelse {
            log.warn("{s}: unknown key {s}", .{ p.source, p.key });
            continue;
        };
        try layered.append(gpa, .{ .field = d.field, .name = d.key, .value = p.value, .src = p.source });
    }
    // env
    if (env_get) |get| {
        for (descs) |d| {
            if (get(env_ctx, d.env)) |v| {
                if (d.kind == .list) {
                    var it = std.mem.splitScalar(u8, v, ',');
                    while (it.next()) |item| {
                        const t = std.mem.trim(u8, item, " ");
                        if (t.len > 0) try layered.append(gpa, .{ .field = d.field, .name = d.env, .value = t, .src = "env" });
                    }
                } else {
                    try layered.append(gpa, .{ .field = d.field, .name = d.env, .value = v, .src = "env" });
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
            try layered.append(gpa, .{ .field = "clients", .name = arg, .value = args[i], .src = "flag" });
            try layered.append(gpa, .{ .field = "discovery", .name = arg, .value = "off", .src = "flag" });
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-discovery")) {
            try layered.append(gpa, .{ .field = "discovery", .name = arg, .value = "off", .src = "flag" });
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const d = descByFlag(arg) orelse return error.BadArgument;
            if (d.kind == .boolean) {
                // optional value; bare flag means on
                if (i + 1 < args.len and parseBool(args[i + 1]) != null) {
                    i += 1;
                    try layered.append(gpa, .{ .field = d.field, .name = d.flag, .value = args[i], .src = "flag" });
                } else {
                    try layered.append(gpa, .{ .field = d.field, .name = d.flag, .value = "on", .src = "flag" });
                }
            } else {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                try layered.append(gpa, .{ .field = d.field, .name = d.flag, .value = args[i], .src = "flag" });
            }
            continue;
        }
        return error.BadArgument;
    }

    // Resolve each field from the layered list.
    var clients: std.ArrayList([]const u8) = .empty;
    var allow: std.ArrayList([]const u8) = .empty;
    var deny: std.ArrayList([]const u8) = .empty;
    var psk: std.ArrayList([]const u8) = .empty;

    for (layered.items) |p| {
        if (std.mem.eql(u8, p.field, "discovery")) {
            s.discovery = parseBool(p.value) orelse blk: {
                log.warn("{s}: ignoring {s} = {s} (want on or off)", .{ p.src, p.name, p.value });
                break :blk s.discovery;
            };
        } else if (std.mem.eql(u8, p.field, "bind")) {
            s.bind = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.field, "subnet")) {
            s.subnet = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.field, "discovery_port")) {
            s.discovery_port = parseIntOr(u16, p, s.discovery_port);
        } else if (std.mem.eql(u8, p.field, "port")) {
            s.port = parseIntOr(u16, p, s.port);
        } else if (std.mem.eql(u8, p.field, "vhci")) {
            s.vhci = try a.dupe(u8, p.value);
        } else if (std.mem.eql(u8, p.field, "reconnect_ms")) {
            s.reconnect_ms = parseIntOr(u32, p, s.reconnect_ms);
        } else if (std.mem.eql(u8, p.field, "clients")) {
            try clients.append(a, try a.dupe(u8, p.value));
        } else if (std.mem.eql(u8, p.field, "allow")) {
            try allow.append(a, try a.dupe(u8, p.value));
        } else if (std.mem.eql(u8, p.field, "deny")) {
            try deny.append(a, try a.dupe(u8, p.value));
        } else if (std.mem.eql(u8, p.field, "psk")) {
            try psk.append(a, try a.dupe(u8, p.value));
        }
    }
    s.clients = try clients.toOwnedSlice(a);
    s.allow = try allow.toOwnedSlice(a);
    s.deny = try deny.toOwnedSlice(a);
    s.psk = try psk.toOwnedSlice(a);
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

test "lookupPsk matches case-insensitively and parses hex" {
    const entries = [_][]const u8{ "AA:BB:CC:DD:EE:01=" ++ ("ab" ** 32), "junk" };
    const p = lookupPsk(&entries, "aa:bb:cc:dd:ee:01").?;
    try testing.expectEqual(@as(u8, 0xab), p[0]);
    try testing.expect(lookupPsk(&entries, "aa:bb:cc:dd:ee:02") == null);
}

test "lookupPsk takes the last entry and skips malformed ones" {
    const later = [_][]const u8{ "aa:bb:cc:dd:ee:01=" ++ ("ab" ** 32), "aa:bb:cc:dd:ee:01=" ++ ("cd" ** 32) };
    try testing.expectEqual(@as(u8, 0xcd), lookupPsk(&later, "aa:bb:cc:dd:ee:01").?[0]);

    const malformed = [_][]const u8{ "aa:bb:cc:dd:ee:01=nothex", "aa:bb:cc:dd:ee:01=" ++ ("ab" ** 32), "aa:bb:cc:dd:ee:01=1234" };
    try testing.expectEqual(@as(u8, 0xab), lookupPsk(&malformed, "aa:bb:cc:dd:ee:01").?[0]);
    try testing.expect(lookupPsk(&.{"aa:bb:cc:dd:ee:01=zz"}, "aa:bb:cc:dd:ee:01") == null);
}

test "bad values fall back and unknown keys are ignored" {
    const conf = [_]config.Pair{
        .{ .key = "port", .value = "70000" },
        .{ .key = "reconnect-ms", .value = "1s" },
        .{ .key = "no-such-key", .value = "1" },
    };
    TestEnv.pairs = &.{.{ "HCIBRIDGE_DISCOVERY", "maybe" }};
    var s = try resolve(testing.allocator, &conf, &.{}, TestEnv.get, null);
    defer s.deinit();
    try testing.expectEqual(@as(u16, 4444), s.port);
    try testing.expectEqual(@as(u32, 1000), s.reconnect_ms);
    try testing.expect(s.discovery);
    TestEnv.pairs = &.{};
}

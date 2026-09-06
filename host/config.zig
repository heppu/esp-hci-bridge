//! Linux-style layered config: a main file plus a `.d` drop-in directory of
//! `*.conf` fragments, merged in order (main first, then drop-ins sorted by
//! name). Scalar keys are last-wins; allow/deny lists accumulate. CLI args,
//! applied by the caller afterwards, override everything here.
//!
//! Format: `key = value`, `#` or `;` comments, blank lines ignored.
//! Keys: host, port, vhci, discovery-port, reconnect-ms, allow, deny.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.config);

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    vhci: ?[]const u8 = null,
    discovery_port: ?u16 = null,
    reconnect_ms: ?u32 = null,
    allow: std.ArrayList([]const u8) = .empty,
    deny: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    fn a(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Applies one fragment's text onto the config.
    pub fn applyText(self: *Config, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                log.warn("ignoring line without '=': {s}", .{line});
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            try self.applyKey(key, val);
        }
    }

    fn applyKey(self: *Config, key: []const u8, val: []const u8) !void {
        const alloc = self.a();
        if (std.mem.eql(u8, key, "host")) {
            self.host = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "port")) {
            self.port = std.fmt.parseInt(u16, val, 10) catch return badValue(key, val);
        } else if (std.mem.eql(u8, key, "vhci")) {
            self.vhci = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "discovery-port")) {
            self.discovery_port = std.fmt.parseInt(u16, val, 10) catch return badValue(key, val);
        } else if (std.mem.eql(u8, key, "reconnect-ms")) {
            self.reconnect_ms = std.fmt.parseInt(u32, val, 10) catch return badValue(key, val);
        } else if (std.mem.eql(u8, key, "allow")) {
            try self.allow.append(alloc, try alloc.dupe(u8, val));
        } else if (std.mem.eql(u8, key, "deny")) {
            try self.deny.append(alloc, try alloc.dupe(u8, val));
        } else {
            log.warn("unknown key: {s}", .{key});
        }
    }

    fn badValue(key: []const u8, val: []const u8) void {
        log.warn("bad value for {s}: {s}", .{ key, val });
    }

    /// True if a discovered bdaddr should be attached given allow/deny rules.
    pub fn permits(self: *const Config, bdaddr: []const u8) bool {
        for (self.deny.items) |d| if (std.ascii.eqlIgnoreCase(d, bdaddr)) return false;
        if (self.allow.items.len == 0) return true;
        for (self.allow.items) |al| if (std.ascii.eqlIgnoreCase(al, bdaddr)) return true;
        return false;
    }
};

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const f = Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        var chunk: [8192]u8 = undefined;
        const n = f.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return try out.toOwnedSlice(gpa);
}

/// Loads `path` then `<path>.d/*.conf` (sorted). Missing files are fine.
pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Config {
    var cfg: Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer cfg.deinit();

    if (try readFile(io, gpa, path)) |main| {
        defer gpa.free(main);
        try cfg.applyText(main);
    }

    var dbuf: [512]u8 = undefined;
    const dpath = std.fmt.bufPrint(&dbuf, "{s}.d", .{path}) catch return cfg;

    var dir = Io.Dir.cwd().openDir(io, dpath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return cfg,
        else => return err,
    };
    defer dir.close(io);

    // Collect *.conf names, sort, apply in order.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    for (names.items) |name| {
        var fbuf: [640]u8 = undefined;
        const fpath = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ dpath, name }) catch continue;
        if (try readFile(io, gpa, fpath)) |frag| {
            defer gpa.free(frag);
            cfg.applyText(frag) catch |err| log.warn("{s}: {s}", .{ name, @errorName(err) });
        }
    }
    return cfg;
}

const testing = std.testing;

test "scalar last-wins and list accumulate" {
    var c: Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer c.deinit();
    try c.applyText("discovery-port = 4445\nallow = aa:bb:cc:dd:ee:01\n# comment\n");
    try c.applyText("discovery-port = 5000\nallow = aa:bb:cc:dd:ee:02\ndeny = ff:ff:ff:ff:ff:ff\n");
    try testing.expectEqual(@as(?u16, 5000), c.discovery_port);
    try testing.expectEqual(@as(usize, 2), c.allow.items.len);
    try testing.expectEqual(@as(usize, 1), c.deny.items.len);
}

test "permits allow/deny logic" {
    var c: Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer c.deinit();
    // no rules: permit all
    try testing.expect(c.permits("aa:bb:cc:dd:ee:01"));
    try c.applyText("allow = AA:BB:CC:DD:EE:01\n");
    try testing.expect(c.permits("aa:bb:cc:dd:ee:01")); // case-insensitive
    try testing.expect(!c.permits("aa:bb:cc:dd:ee:99")); // not in allowlist
    try c.applyText("deny = aa:bb:cc:dd:ee:01\n");
    try testing.expect(!c.permits("aa:bb:cc:dd:ee:01")); // deny wins
}

test "ignores junk lines" {
    var c: Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer c.deinit();
    try c.applyText("garbage without equals\nport = 4444\nunknownkey = x\n");
    try testing.expectEqual(@as(?u16, 4444), c.port);
}

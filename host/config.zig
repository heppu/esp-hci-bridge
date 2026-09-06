//! Layered config file reader: a main file plus a `.d` directory of `*.conf`
//! fragments, merged in order (main first, then drop-ins sorted by name).
//! Returns raw `key = value` pairs in order; typing and precedence live in
//! settings.zig so this stays a dumb, testable reader.
//!
//! Format: `key = value`, `#` or `;` comments, blank lines ignored.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.config);

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Raw = struct {
    arena: std.heap.ArenaAllocator,
    pairs: std.ArrayList(Pair) = .empty,

    pub fn deinit(self: *Raw) void {
        self.arena.deinit();
    }

    pub fn applyText(self: *Raw, text: []const u8) !void {
        const alloc = self.arena.allocator();
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
            if (key.len == 0) continue;
            try self.pairs.append(alloc, .{
                .key = try alloc.dupe(u8, key),
                .value = try alloc.dupe(u8, val),
            });
        }
    }
};

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
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

/// Reads `path` then `<path>.d/*.conf` (sorted). Missing files are fine.
pub fn loadRaw(gpa: std.mem.Allocator, io: Io, path: []const u8) !Raw {
    var raw: Raw = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer raw.deinit();

    if (try readFile(io, gpa, path)) |main| {
        defer gpa.free(main);
        try raw.applyText(main);
    }

    var dbuf: [512]u8 = undefined;
    const dpath = std.fmt.bufPrint(&dbuf, "{s}.d", .{path}) catch return raw;

    var dir = Io.Dir.cwd().openDir(io, dpath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return raw,
        else => return err,
    };
    defer dir.close(io);

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
            raw.applyText(frag) catch |err| log.warn("{s}: {s}", .{ name, @errorName(err) });
        }
    }
    return raw;
}

const testing = std.testing;

test "pairs preserve order and repetition" {
    var r: Raw = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer r.deinit();
    try r.applyText("a = 1\n# c\nb = 2\na = 3\n");
    try testing.expectEqual(@as(usize, 3), r.pairs.items.len);
    try testing.expectEqualStrings("a", r.pairs.items[0].key);
    try testing.expectEqualStrings("3", r.pairs.items[2].value);
}

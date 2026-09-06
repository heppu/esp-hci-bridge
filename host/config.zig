//! Layered config file reader: a main file plus a `.d` directory of `*.conf`
//! fragments, merged in order (main first, then drop-ins sorted by name).
//! Returns raw `key = value` pairs in order; typing and precedence live in
//! settings.zig so this stays a dumb, testable reader.
//!
//! Format: `key = value`, `#` or `;` comments (also after a value), blank
//! lines ignored.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.config);

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
    /// File the pair came from, for diagnostics.
    source: []const u8 = "config",
};

pub const Raw = struct {
    arena: std.heap.ArenaAllocator,
    pairs: std.ArrayList(Pair) = .empty,

    pub fn deinit(self: *Raw) void {
        self.arena.deinit();
    }

    pub fn applyText(self: *Raw, text: []const u8) !void {
        return self.applyTextFrom(text, "config");
    }

    pub fn applyTextFrom(self: *Raw, text: []const u8, source: []const u8) !void {
        const alloc = self.arena.allocator();
        const src = try alloc.dupe(u8, source);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                log.warn("{s}: ignoring line without '=': {s}", .{ source, line });
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (key.len == 0) continue;
            try self.pairs.append(alloc, .{
                .key = try alloc.dupe(u8, key),
                .value = try alloc.dupe(u8, val),
                .source = src,
            });
        }
    }
};

/// A `#` or `;` at the start of the line or after whitespace begins a comment.
fn stripComment(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != '#' and c != ';') continue;
        if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') return line[0..i];
    }
    return line;
}

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

/// Reads `path` then `<path>.d/*.conf` (sorted). Missing files are fine, an
/// unreadable drop-in is skipped with a warning.
pub fn loadRaw(gpa: std.mem.Allocator, io: Io, path: []const u8) !Raw {
    var raw: Raw = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer raw.deinit();

    if (try readFile(io, gpa, path)) |main| {
        defer gpa.free(main);
        try raw.applyTextFrom(main, path);
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
        switch (entry.kind) {
            .file, .sym_link, .unknown => {},
            else => continue,
        }
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
        const frag = readFile(io, gpa, fpath) catch |err| {
            log.warn("{s}: {s}, skipping", .{ fpath, @errorName(err) });
            continue;
        } orelse {
            log.warn("{s}: not found, skipping", .{fpath});
            continue;
        };
        defer gpa.free(frag);
        raw.applyTextFrom(frag, fpath) catch |err| log.warn("{s}: {s}", .{ fpath, @errorName(err) });
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

test "inline comments after a value are stripped" {
    var r: Raw = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer r.deinit();
    try r.applyText("port = 4444  # x\nvhci = /dev/vhci ; y\nname = a#b\n");
    try testing.expectEqual(@as(usize, 3), r.pairs.items.len);
    try testing.expectEqualStrings("4444", r.pairs.items[0].value);
    try testing.expectEqualStrings("/dev/vhci", r.pairs.items[1].value);
    try testing.expectEqualStrings("a#b", r.pairs.items[2].value);
}

test "drop-ins include regular files and symlinks, unreadable ones are skipped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "a = main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.d/10-a.conf", .data = "a = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "b = 2\n" });
    try tmp.dir.symLink(io, "../target.txt", "config.d/20-b.conf", .{});
    try tmp.dir.symLink(io, "missing.txt", "config.d/30-dangling.conf", .{});

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cbuf, "{s}/config", .{pbuf[0..n]});

    var r = try loadRaw(testing.allocator, io, cfg);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.pairs.items.len);
    try testing.expectEqualStrings("main", r.pairs.items[0].value);
    try testing.expectEqualStrings("1", r.pairs.items[1].value);
    try testing.expectEqualStrings("b", r.pairs.items[2].key);
    try testing.expectEqualStrings("2", r.pairs.items[2].value);
    try testing.expect(std.mem.endsWith(u8, r.pairs.items[2].source, "20-b.conf"));
}

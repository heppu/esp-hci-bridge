//! Fetches firmware images from the project's GitHub releases.
const std = @import("std");
const Io = std.Io;

pub const repo = "heppu/esp-hci-bridge";
const api_latest = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
const download_base = "https://github.com/" ++ repo ++ "/releases/download/";
const max_body = 4 * 1024 * 1024;

pub const Latest = struct {
    tag: []const u8,
    sums: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Latest) void {
        self.arena.deinit();
    }

    pub fn imageName(board: []const u8, buf: *[128]u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "esp-hci-bridge-{s}.bin", .{board});
    }

    /// Downloads and hash-checks the image for one board preset. Caller frees.
    pub fn image(self: *Latest, client: *std.http.Client, gpa: std.mem.Allocator, board: []const u8) ![]u8 {
        var nbuf: [128]u8 = undefined;
        const name = try imageName(board, &nbuf);
        const expected = sumFor(self.sums, name) orelse return error.NoSuchBoardImage;
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}{s}/{s}", .{ download_base, self.tag, name });
        const body = try get(client, gpa, url);
        errdefer gpa.free(body);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, expected)) return error.ChecksumMismatch;
        return body;
    }
};

/// Looks up the latest release tag and its checksum list.
pub fn latest(client: *std.http.Client, gpa: std.mem.Allocator) !Latest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const meta = try get(client, a, api_latest);
    const tag = tagName(meta) orelse return error.NoTagInRelease;
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}/SHA256SUMS", .{ download_base, tag });
    const sums = try get(client, a, url);
    return .{ .tag = tag, .sums = sums, .arena = arena };
}

fn get(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
        .extra_headers = &.{.{ .name = "user-agent", .value = "hcibridge" }},
    });
    if (res.status != .ok) return error.HttpStatus;
    if (out.written().len > max_body) return error.ResponseTooLarge;
    return out.toOwnedSlice();
}

/// Pulls "tag_name" out of the release JSON without a full parser.
pub fn tagName(json: []const u8) ?[]const u8 {
    const key = "\"tag_name\":";
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, json, i, '"') orelse return null;
    const tag = json[i..end];
    if (tag.len == 0 or tag.len > 64) return null;
    for (tag) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return null;
    return tag;
}

/// Finds the hex digest for `name` in a sha256sum style listing.
pub fn sumFor(sums: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const hex = line[0..sp];
        var rest = std.mem.trim(u8, line[sp..], " ");
        if (rest.len > 0 and rest[0] == '*') rest = rest[1..];
        if (hex.len == 64 and std.mem.eql(u8, rest, name)) return hex;
    }
    return null;
}

test "tag name from release json" {
    try std.testing.expectEqualStrings("v0.10.8", tagName("{\"url\":\"x\",\"tag_name\": \"v0.10.8\",\"name\":\"y\"}").?);
    try std.testing.expect(tagName("{\"name\":\"y\"}") == null);
    try std.testing.expect(tagName("{\"tag_name\":\"../evil\"}") == null);
}

test "sum lookup" {
    const sums = "aa" ** 32 ++ "  esp-hci-bridge-olimex-esp32-poe.bin\n" ++ "bb" ** 32 ++ " *other.bin\n";
    try std.testing.expectEqualStrings("aa" ** 32, sumFor(sums, "esp-hci-bridge-olimex-esp32-poe.bin").?);
    try std.testing.expectEqualStrings("bb" ** 32, sumFor(sums, "other.bin").?);
    try std.testing.expect(sumFor(sums, "missing.bin") == null);
}

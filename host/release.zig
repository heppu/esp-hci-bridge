//! Fetches firmware images from the project's GitHub releases.
const std = @import("std");
const Io = std.Io;

const log = std.log;
const ui = @import("ui.zig");

pub const repo = "heppu/esp-hci-bridge";
const latest_url = "https://github.com/" ++ repo ++ "/releases/latest";
const download_base = "https://github.com/" ++ repo ++ "/releases/download/";
const max_body = 4 * 1024 * 1024;
const attempts = 3;
// Overrides the client default rather than adding a second user-agent line,
// which some CDN frontends reject with 400.
const headers = std.http.Client.Request.Headers{ .user_agent = .{ .override = "hcibridge" } };

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
    pub fn image(self: *Latest, client: *std.http.Client, gpa: std.mem.Allocator, board: []const u8, out: ?*ui.Ui) ![]u8 {
        var nbuf: [128]u8 = undefined;
        const name = try imageName(board, &nbuf);
        const expected = sumFor(self.sums, name) orelse return error.NoSuchBoardImage;
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}{s}/{s}", .{ download_base, self.tag, name });
        const body = try getShow(client, gpa, url, out, name);
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
    const tag = try retry(latestTag, .{ client, a });
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}/SHA256SUMS", .{ download_base, tag });
    const sums = try get(client, a, url);
    return .{ .tag = tag, .sums = sums, .arena = arena };
}

/// The release page redirects to /releases/tag/<tag>. No API call, so no
/// unauthenticated rate limit to run into.
fn latestTag(client: *std.http.Client, gpa: std.mem.Allocator) ![]const u8 {
    const uri = try std.Uri.parse(latest_url);
    // The redirect body is never read, so do not hand this connection back to the pool.
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .headers = headers, .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();
    var rbuf: [8192]u8 = undefined;
    var res = try req.receiveHead(&rbuf);
    if (res.head.status.class() != .redirect) {
        log.err("GET {s}: HTTP {d}, expected a redirect to the latest tag", .{ latest_url, @intFromEnum(res.head.status) });
        return error.HttpStatus;
    }
    const loc = res.head.location orelse return error.NoRedirectLocation;
    const tag = tagFromLocation(loc) orelse return error.NoTagInRedirect;
    return gpa.dupe(u8, tag);
}

fn get(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    return retry(getOnce, .{ client, gpa, url, @as(?*ui.Ui, null), @as([]const u8, "") });
}

fn getShow(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8, out: ?*ui.Ui, label: []const u8) ![]u8 {
    return retry(getOnce, .{ client, gpa, url, out, label });
}

/// Follows redirects by hand: the client's own redirect path re-encodes the
/// signed asset URLs GitHub hands out and the CDN answers 400 to the result.
fn getOnce(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8, out: ?*ui.Ui, label: []const u8) ![]u8 {
    var loc_buf: [4096]u8 = undefined;
    var cur: []const u8 = url;
    var hops: usize = 0;
    while (hops < 6) : (hops += 1) {
        const uri = try std.Uri.parse(cur);
        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .headers = headers, .keep_alive = false });
        defer req.deinit();
        try req.sendBodiless();
        var rbuf: [8192]u8 = undefined;
        var res = try req.receiveHead(&rbuf);
        const status = res.head.status;
        if (status.class() == .redirect) {
            const loc = res.head.location orelse return error.NoRedirectLocation;
            if (loc.len > loc_buf.len) return error.RedirectTooLong;
            @memcpy(loc_buf[0..loc.len], loc);
            cur = loc_buf[0..loc.len];
            continue;
        }
        if (status != .ok) {
            var ebuf: [512]u8 = undefined;
            var tb: [4096]u8 = undefined;
            const n = res.reader(&tb).readSliceShort(&ebuf) catch 0;
            log.warn("GET {s}: HTTP {d} {s}", .{ cur, @intFromEnum(status), std.mem.trim(u8, ebuf[0..n], " \r\n") });
            // A rejected signed link is worth one more round trip through the
            // first hop, which hands out a fresh one.
            if (hops > 0 and (status == .bad_request or status == .forbidden)) return error.AssetNotReadyYet;
            return error.HttpStatus;
        }
        var tbuf: [16 * 1024]u8 = undefined;
        const body = res.reader(&tbuf);
        const total: usize = @intCast(res.head.content_length orelse 0);
        var bar: ?ui.Progress = if (out) |u| u.progress("Downloading {s}", .{label}, total) else null;
        var acc: Io.Writer.Allocating = .init(gpa);
        defer acc.deinit();
        while (true) {
            var chunk: [16 * 1024]u8 = undefined;
            const n = body.readSliceShort(&chunk) catch return error.ReadFailed;
            if (n == 0) break;
            acc.writer.writeAll(chunk[0..n]) catch return error.OutOfMemory;
            if (acc.written().len > max_body) return error.ResponseTooLarge;
            if (bar) |*b| b.update(acc.written().len);
        }
        if (bar) |*b| b.finish(acc.written().len);
        return acc.toOwnedSlice();
    }
    return error.TooManyRedirects;
}

/// A flaky resolver or a dropped connection should not fail an update outright.
fn retry(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    var n: usize = 0;
    while (true) : (n += 1) {
        return @call(.auto, f, args) catch |err| {
            if (n + 1 >= attempts or !transient(err)) return err;
            log.warn("{s}, retrying ({d}/{d})", .{ @errorName(err), n + 2, attempts });
            args[0].io.sleep(Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };
    }
}

fn transient(err: anyerror) bool {
    return switch (err) {
        error.AssetNotReadyYet, error.NameServerFailure, error.TemporaryNameServerFailure, error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostLacksNetworkAddresses, error.EndOfStream, error.UnexpectedReadFailure, error.UnexpectedWriteFailure, error.HttpConnectionClosing => true,
        else => false,
    };
}

/// Pulls the tag out of a "/releases/tag/<tag>" location, absolute or relative.
pub fn tagFromLocation(loc: []const u8) ?[]const u8 {
    const marker = "/releases/tag/";
    const at = std.mem.indexOf(u8, loc, marker) orelse return null;
    var tag = loc[at + marker.len ..];
    if (std.mem.indexOfAny(u8, tag, "?#/")) |end| tag = tag[0..end];
    if (tag.len == 0 or tag.len > 64 or !std.ascii.isAlphanumeric(tag[0])) return null;
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

test "tag from redirect location" {
    try std.testing.expectEqualStrings("v0.10.9", tagFromLocation("https://github.com/heppu/esp-hci-bridge/releases/tag/v0.10.9").?);
    try std.testing.expectEqualStrings("v0.10.9", tagFromLocation("/heppu/esp-hci-bridge/releases/tag/v0.10.9?x=1").?);
    try std.testing.expect(tagFromLocation("https://github.com/heppu/esp-hci-bridge/releases") == null);
    try std.testing.expect(tagFromLocation("/releases/tag/../evil") == null);
}

test "sum lookup" {
    const sums = "aa" ** 32 ++ "  esp-hci-bridge-olimex-esp32-poe.bin\n" ++ "bb" ** 32 ++ " *other.bin\n";
    try std.testing.expectEqualStrings("aa" ** 32, sumFor(sums, "esp-hci-bridge-olimex-esp32-poe.bin").?);
    try std.testing.expectEqualStrings("bb" ** 32, sumFor(sums, "other.bin").?);
    try std.testing.expect(sumFor(sums, "missing.bin") == null);
}

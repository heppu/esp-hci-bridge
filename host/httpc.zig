//! Minimal HTTP/1.1 client over Io.net for talking to a bridge's status and
//! OTA endpoints. Plain HTTP on the LAN, no TLS, no keep-alive: every request
//! sends "Connection: close" and reads the response until the peer closes.

const std = @import("std");
const Io = std.Io;

pub const http_port: u16 = 80;
/// Largest response accepted, header and body together.
pub const max_body: usize = 1 << 20;

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

fn contentLength(head: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
        }
    }
    return null;
}

/// Total bytes to expect once the header is in, null while the header is
/// incomplete or carries no Content-Length.
fn expectedLen(buf: []const u8) error{ResponseTooLarge}!?usize {
    const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const cl = contentLength(buf[0..sep]) orelse return null;
    if (cl > max_body) return error.ResponseTooLarge;
    return std.math.add(usize, sep + 4, @intCast(cl)) catch error.ResponseTooLarge;
}

fn parseResponse(gpa: std.mem.Allocator, bytes: []const u8) !Response {
    const sep = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.BadResponse;
    const head = bytes[0..sep];
    var body = bytes[sep + 4 ..];
    if (contentLength(head)) |cl| {
        if (cl < body.len) body = body[0..@intCast(cl)];
    }

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.BadResponse;
    const code_s = parts.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, code_s, 10) catch return error.BadResponse;
    return .{ .status = status, .body = try gpa.dupe(u8, body) };
}

/// Reads a full HTTP response. Honors Content-Length so it does not hang on a
/// keep-alive connection; falls back to read-until-close when absent.
fn readResponse(io: Io, stream: Io.net.Stream, gpa: std.mem.Allocator) !Response {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const r = &reader.interface;

    while (true) {
        if (try expectedLen(buf.items)) |want| {
            if (buf.items.len >= want) break;
        } else if (buf.items.len > max_body) return error.ResponseTooLarge;

        // fill(1) returns as soon as anything arrives instead of filling the buffer.
        r.fill(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const avail = r.buffered();
        if (avail.len == 0) break;
        try buf.appendSlice(gpa, avail);
        r.tossBuffered();
    }
    return parseResponse(gpa, buf.items);
}

pub fn get(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, path: []const u8) !Response {
    return getH(io, gpa, addr, path, null);
}

/// GET with an optional extra header line (without CRLF), e.g. "X-Bridge-Auth: ...".
pub fn getH(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, path: []const u8, extra: ?[]const u8) !Response {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nHost: bridge\r\nConnection: close\r\n", .{path});
    if (extra) |h| try w.interface.print("{s}\r\n", .{h});
    try w.interface.writeAll("\r\n");
    try w.interface.flush();
    return readResponse(io, stream, gpa);
}

pub fn postBinary(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, path: []const u8, body: []const u8) !Response {
    return postH(io, gpa, addr, path, body, null);
}

/// POST with an optional extra header line (without CRLF).
pub fn postH(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, path: []const u8, body: []const u8, extra: ?[]const u8) !Response {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("POST {s} HTTP/1.1\r\nHost: bridge\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ path, body.len });
    if (extra) |h| try w.interface.print("{s}\r\n", .{h});
    try w.interface.writeAll("\r\n");
    try w.interface.writeAll(body);
    try w.interface.flush();
    return readResponse(io, stream, gpa);
}

/// True if the flat JSON has `"key":true`.
pub fn jsonBool(body: []const u8, key: []const u8) ?bool {
    var pat: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&pat, "\"{s}\":true", .{key}) catch return null;
    if (std.mem.indexOf(u8, body, t) != null) return true;
    const f = std.fmt.bufPrint(&pat, "\"{s}\":false", .{key}) catch return null;
    if (std.mem.indexOf(u8, body, f) != null) return false;
    return null;
}

/// Pulls one string field out of the flat status JSON, e.g. "version".
pub fn jsonField(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, pat) orelse return null;
    const vstart = start + pat.len;
    const end = std.mem.indexOfScalarPos(u8, body, vstart, '"') orelse return null;
    const v = body[vstart..end];
    if (v.len > out.len) return null;
    @memcpy(out[0..v.len], v);
    return out[0..v.len];
}

const testing = std.testing;

test "contentLength parsing" {
    try testing.expectEqual(@as(?u64, 3), contentLength("HTTP/1.1 200 OK\r\nContent-Length: 3"));
    try testing.expectEqual(@as(?u64, null), contentLength("HTTP/1.1 200 OK"));
}

test "expectedLen waits for the header and caps Content-Length" {
    try testing.expectEqual(@as(?usize, null), try expectedLen("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"));
    try testing.expectEqual(@as(?usize, null), try expectedLen("HTTP/1.1 200 OK\r\n\r\nabc"));
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n";
    try testing.expectEqual(@as(?usize, head.len + 3), try expectedLen(head ++ "a"));
    try testing.expectError(error.ResponseTooLarge, expectedLen("HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n"));
    try testing.expectError(error.ResponseTooLarge, expectedLen("HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551615\r\n\r\n"));
}

test "parseResponse splits status and body" {
    var r = try parseResponse(testing.allocator, "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabcdef");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), r.status);
    try testing.expectEqualStrings("abc", r.body);

    var r2 = try parseResponse(testing.allocator, "HTTP/1.1 200 OK\r\n\r\n{\"a\":1}");
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r2.status);
    try testing.expectEqualStrings("{\"a\":1}", r2.body);

    try testing.expectError(error.BadResponse, parseResponse(testing.allocator, "HTTP/1.1 200 OK\r\n"));
    try testing.expectError(error.BadResponse, parseResponse(testing.allocator, "HTTP/1.1 abc\r\n\r\n"));
    try testing.expectError(error.BadResponse, parseResponse(testing.allocator, "\r\n\r\n"));
}

test "jsonField extracts value" {
    var buf: [64]u8 = undefined;
    const v = jsonField("{\"version\":\"v0.3.0\",\"partition\":\"ota_0\"}", "version", &buf).?;
    try testing.expectEqualStrings("v0.3.0", v);
    try testing.expect(jsonField("{}", "version", &buf) == null);
}

//! Minimal HTTP/1.1 client over Io.net for talking to a bridge's status and
//! OTA endpoints. Plain HTTP on the LAN, no TLS, no keep-alive: every request
//! sends "Connection: close" and reads the response until the peer closes.

const std = @import("std");
const Io = std.Io;

pub const http_port: u16 = 80;

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
        }
    }
    return null;
}

/// Reads a full HTTP response. Honors Content-Length so it does not hang on a
/// keep-alive connection; falls back to read-until-close when absent.
fn readResponse(io: Io, stream: Io.net.Stream, gpa: std.mem.Allocator) !Response {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);

    const r = &reader.interface;
    var header_end: ?usize = null;
    var want: ?usize = null; // total bytes = header_end + 4 + content-length

    while (true) {
        if (header_end == null) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |sep| {
                header_end = sep;
                if (contentLength(buf.items[0..sep])) |cl| want = sep + 4 + cl;
            }
        }
        if (want) |w| if (buf.items.len >= w) break;

        // Block for at least one byte, then drain whatever is buffered. This
        // returns as data arrives instead of waiting to fill a fixed buffer.
        r.fill(1) catch break; // EndOfStream ends the read
        const avail = r.buffered();
        if (avail.len == 0) break;
        try buf.appendSlice(gpa, avail);
        r.tossBuffered();
    }

    const sep = header_end orelse return error.BadResponse;
    const head = buf.items[0..sep];
    const body_all = buf.items[sep + 4 ..];
    const body = if (want) |w| buf.items[sep + 4 .. @min(w, buf.items.len)] else body_all;

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.BadResponse;
    const code_s = parts.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, code_s, 10) catch return error.BadResponse;
    return .{ .status = status, .body = try gpa.dupe(u8, body) };
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
    try testing.expectEqual(@as(?usize, 3), contentLength("HTTP/1.1 200 OK\r\nContent-Length: 3"));
    try testing.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK"));
}

test "jsonField extracts value" {
    var buf: [64]u8 = undefined;
    const v = jsonField("{\"version\":\"v0.3.0\",\"partition\":\"ota_0\"}", "version", &buf).?;
    try testing.expectEqualStrings("v0.3.0", v);
    try testing.expect(jsonField("{}", "version", &buf) == null);
}

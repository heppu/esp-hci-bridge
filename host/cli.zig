//! One-shot CLI commands: discover bridges, show status, push OTA updates.

const std = @import("std");
const Io = std.Io;
const disc = @import("discovery");
const httpc = @import("httpc.zig");

const log = std.log;

pub const Bridge = struct {
    addr: Io.net.IpAddress,
    bdaddr_buf: [17]u8 = undefined,
    bdaddr_len: usize = 0,
    name_buf: [63]u8 = undefined,
    name_len: usize = 0,

    fn bdaddr(self: *const Bridge) []const u8 {
        return self.bdaddr_buf[0..self.bdaddr_len];
    }
    fn name(self: *const Bridge) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Broadcasts a probe and collects announcements for `window_ms`, deduped by
/// bdaddr. Caller frees the slice.
pub fn collect(io: Io, gpa: std.mem.Allocator, discovery_port: u16, window_ms: u32) ![]Bridge {
    var found: std.ArrayList(Bridge) = .empty;
    errdefer found.deinit(gpa);

    const sock = try (Io.net.IpAddress{ .ip4 = .unspecified(0) }).bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer sock.close(io);

    const bcast: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = discovery_port } };
    var pbuf: [64]u8 = undefined;
    sock.send(io, &bcast, disc.buildProbe(&pbuf)) catch {};

    var rbuf: [disc.max_datagram]u8 = undefined;
    const tick_ms: u32 = 250;
    var ticks = @max(@as(u32, 1), window_ms / tick_ms);
    while (ticks > 0) {
        const msg = sock.receiveTimeout(io, &rbuf, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(tick_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {
                ticks -= 1;
                continue;
            },
            else => break,
        };
        const parsed = disc.parse(msg.data) catch continue;
        const ann = switch (parsed) {
            .announce => |a| a,
            .probe => continue,
        };
        var dup = false;
        for (found.items) |*b| {
            if (std.mem.eql(u8, b.bdaddr(), ann.bdaddr)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (ann.bdaddr.len > 17 or ann.name.len > 63) continue;
        var b: Bridge = .{ .addr = msg.from };
        b.addr.setPort(ann.port);
        @memcpy(b.bdaddr_buf[0..ann.bdaddr.len], ann.bdaddr);
        b.bdaddr_len = ann.bdaddr.len;
        @memcpy(b.name_buf[0..ann.name.len], ann.name);
        b.name_len = ann.name.len;
        try found.append(gpa, b);
    }
    return found.toOwnedSlice(gpa);
}

fn printStatus(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, b: *const Bridge) void {
    var abuf: [24]u8 = undefined;
    const astr = std.fmt.bufPrint(&abuf, "{f}", .{b.addr}) catch "?";
    var status_addr = b.addr;
    status_addr.setPort(httpc.http_port);
    var r = httpc.get(io, gpa, &status_addr, "/") catch {
        w.print("{s:<18} {s:<21} {s:<17} (unreachable)\n", .{ b.name(), astr, b.bdaddr() }) catch {};
        return;
    };
    defer r.deinit(gpa);
    var vbuf: [32]u8 = undefined;
    var pbuf: [16]u8 = undefined;
    const ver = httpc.jsonField(r.body, "version", &vbuf) orelse "?";
    const part = httpc.jsonField(r.body, "partition", &pbuf) orelse "?";
    w.print("{s:<18} {s:<21} {s:<17} {s:<12} {s}\n", .{ b.name(), astr, b.bdaddr(), ver, part }) catch {};
}

pub fn list(io: Io, gpa: std.mem.Allocator, discovery_port: u16, window_ms: u32) !u8 {
    const bridges = try collect(io, gpa, discovery_port, window_ms);
    defer gpa.free(bridges);
    var obuf: [256]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);
    const w = &out.interface;
    if (bridges.len == 0) {
        try w.writeAll("no bridges found\n");
        try w.flush();
        return 0;
    }
    try w.print("{s:<18} {s:<21} {s:<17} {s:<12} {s}\n", .{ "NAME", "ADDRESS", "BDADDR", "VERSION", "SLOT" });
    for (bridges) |*b| printStatus(io, gpa, w, b);
    try w.flush();
    return 0;
}

pub fn status(io: Io, gpa: std.mem.Allocator, ip: []const u8) !u8 {
    const addr: Io.net.IpAddress = .{ .ip4 = try Io.net.Ip4Address.parse(ip, 80) };
    var r = httpc.get(io, gpa, &addr, "/") catch |err| {
        log.err("cannot reach {s}: {s}", .{ ip, @errorName(err) });
        return 1;
    };
    defer r.deinit(gpa);
    var obuf: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);
    try out.interface.writeAll(r.body);
    if (r.body.len == 0 or r.body[r.body.len - 1] != '\n') try out.interface.writeAll("\n");
    try out.interface.flush();
    return 0;
}

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        var chunk: [16384]u8 = undefined;
        const n = f.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn updateOne(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, image: []const u8) bool {
    var before = httpc.get(io, gpa, addr, "/") catch null;
    if (before) |*b| {
        var vbuf: [32]u8 = undefined;
        const v = httpc.jsonField(b.body, "version", &vbuf) orelse "?";
        log.info("updating {f} (currently {s}), {d} bytes", .{ addr.*, v, image.len });
        b.deinit(gpa);
    } else {
        log.info("updating {f}, {d} bytes", .{ addr.*, image.len });
    }
    var r = httpc.postBinary(io, gpa, addr, "/ota", image) catch |err| {
        log.err("  ota failed: {s}", .{@errorName(err)});
        return false;
    };
    defer r.deinit(gpa);
    if (r.status != 200) {
        log.err("  ota rejected: HTTP {d} {s}", .{ r.status, std.mem.trim(u8, r.body, " \r\n") });
        return false;
    }
    log.info("  sent, board rebooting", .{});
    return true;
}

pub fn update(io: Io, gpa: std.mem.Allocator, target: []const u8, path: []const u8, discovery_port: u16) !u8 {
    const image = readFile(io, gpa, path) catch |err| {
        log.err("cannot read {s}: {s}", .{ path, @errorName(err) });
        return 1;
    };
    defer gpa.free(image);

    if (std.mem.eql(u8, target, "all")) {
        const bridges = try collect(io, gpa, discovery_port, 2500);
        defer gpa.free(bridges);
        if (bridges.len == 0) {
            log.err("no bridges found to update", .{});
            return 1;
        }
        var ok: usize = 0;
        for (bridges) |*b| {
            var a = b.addr;
            a.setPort(80);
            if (updateOne(io, gpa, &a, image)) ok += 1;
        }
        log.info("updated {d}/{d} bridges", .{ ok, bridges.len });
        return if (ok == bridges.len) 0 else 1;
    }

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(target, 80) catch {
        log.err("target must be an IPv4 address or 'all'", .{});
        return 2;
    } };
    return if (updateOne(io, gpa, &addr, image)) 0 else 1;
}

//! One-shot CLI commands: discover bridges, show status, push OTA updates.

const std = @import("std");
const Io = std.Io;
const disc = @import("discovery");
const auth = @import("auth");
const httpc = @import("httpc.zig");
const config = @import("config.zig");
const settings = @import("settings.zig");
const X25519 = std.crypto.dh.X25519;

pub const default_config = "/etc/hcibridge/config";

/// Loads psk entries from the config (main + .d). Caller deinit()s.
fn loadKeys(io: Io, gpa: std.mem.Allocator, cfg_path: []const u8) !settings.Settings {
    var raw = config.loadRaw(gpa, io, cfg_path) catch config.Raw{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer raw.deinit();
    return settings.resolve(gpa, raw.pairs.items, &.{}, null, null);
}

fn boardInfo(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, bdaddr_out: *[17]u8) !struct { bdaddr: []const u8, claimed: ?bool } {
    var r = try httpc.get(io, gpa, addr, "/");
    defer r.deinit(gpa);
    var buf: [32]u8 = undefined;
    const b = httpc.jsonField(r.body, "bdaddr", &buf) orelse return error.NoBdaddr;
    if (b.len != 17) return error.NoBdaddr;
    @memcpy(bdaddr_out, b);
    return .{ .bdaddr = bdaddr_out, .claimed = httpc.jsonBool(r.body, "claimed") };
}

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
    const claimed: []const u8 = if (httpc.jsonBool(r.body, "claimed")) |c| (if (c) "claimed" else "UNCLAIMED") else "?";
    w.print("{s:<18} {s:<21} {s:<17} {s:<10} {s:<7} {s}\n", .{ b.name(), astr, b.bdaddr(), ver, part, claimed }) catch {};
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
    try w.print("{s:<18} {s:<21} {s:<17} {s:<10} {s:<7} {s}\n", .{ "NAME", "ADDRESS", "BDADDR", "VERSION", "SLOT", "KEY" });
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

fn authHeader(psk: *const auth.Psk, method: []const u8, path: []const u8, body: []const u8, out: *[80]u8) []const u8 {
    var mac: [auth.mac_len * 2]u8 = undefined;
    _ = auth.httpAuth(psk, method, path, body, &mac);
    return std.fmt.bufPrint(out, "X-Bridge-Auth: {s}", .{&mac}) catch unreachable;
}

fn updateOne(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, image: []const u8, keys: *const settings.Settings) bool {
    var bd: [17]u8 = undefined;
    const info = boardInfo(io, gpa, addr, &bd) catch |err| {
        log.err("cannot query {f}: {s}", .{ addr.*, @errorName(err) });
        return false;
    };
    // Firmware before v0.10 reports no claim state and takes unauthenticated
    // uploads, which is the only way to move such a board onto keyed firmware.
    var hbuf: [80]u8 = undefined;
    var hdr: ?[]const u8 = null;
    if (info.claimed != null) {
        const psk = settings.lookupPsk(keys.psk, info.bdaddr) orelse {
            log.err("no key for {s} ({f}): run `hcibridge claim` first", .{ info.bdaddr, addr.* });
            return false;
        };
        hdr = authHeader(&psk, "POST", "/ota", image, &hbuf);
    } else log.warn("{f} runs pre-key firmware, sending unauthenticated update", .{addr.*});
    log.info("updating {f} ({s}), {d} bytes", .{ addr.*, info.bdaddr, image.len });
    var r = httpc.postH(io, gpa, addr, "/ota", image, hdr) catch |err| {
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

pub fn update(io: Io, gpa: std.mem.Allocator, target: []const u8, path: []const u8, discovery_port: u16, cfg_path: []const u8) !u8 {
    const image = readFile(io, gpa, path) catch |err| {
        log.err("cannot read {s}: {s}", .{ path, @errorName(err) });
        return 1;
    };
    defer gpa.free(image);
    var keys = try loadKeys(io, gpa, cfg_path);
    defer keys.deinit();

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
            if (updateOne(io, gpa, &a, image, &keys)) ok += 1;
        }
        log.info("updated {d}/{d} bridges", .{ ok, bridges.len });
        return if (ok == bridges.len) 0 else 1;
    }

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(target, 80) catch {
        log.err("target must be an IPv4 address or 'all'", .{});
        return 2;
    } };
    return if (updateOne(io, gpa, &addr, image, &keys)) 0 else 1;
}

pub fn reboot(io: Io, gpa: std.mem.Allocator, ip: []const u8, cfg_path: []const u8) !u8 {
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(ip, httpc.http_port) catch {
        log.err("bad ip: {s}", .{ip});
        return 2;
    } };
    var keys = try loadKeys(io, gpa, cfg_path);
    defer keys.deinit();
    var bd: [17]u8 = undefined;
    const info = try boardInfo(io, gpa, &addr, &bd);
    const psk = settings.lookupPsk(keys.psk, info.bdaddr) orelse {
        log.err("no key for {s}: run `hcibridge claim {s}` first", .{ info.bdaddr, ip });
        return 1;
    };
    var hbuf: [80]u8 = undefined;
    const hdr = authHeader(&psk, "POST", "/reboot", "", &hbuf);
    var r = try httpc.postH(io, gpa, &addr, "/reboot", "", hdr);
    defer r.deinit(gpa);
    if (r.status != 200) {
        log.err("reboot rejected: HTTP {d}", .{r.status});
        return 1;
    }
    log.info("{s} rebooting", .{ip});
    return 0;
}

/// Pairs with an unclaimed board: X25519 exchange, PSK = SHA256(shared),
/// written as a drop-in under <config>.d/. First claim wins; re-keying needs
/// a factory reset of the board.
pub fn claim(io: Io, gpa: std.mem.Allocator, ip: []const u8, cfg_path: []const u8) !u8 {
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(ip, httpc.http_port) catch {
        log.err("bad ip: {s}", .{ip});
        return 2;
    } };
    var bd: [17]u8 = undefined;
    const info = try boardInfo(io, gpa, &addr, &bd);
    const claimed = info.claimed orelse {
        log.err("{s} ({s}) runs firmware without key support: update it first.", .{ ip, info.bdaddr });
        return 1;
    };
    if (claimed) {
        log.err("{s} ({s}) is already claimed. To re-key it, factory-reset the board first.", .{ ip, info.bdaddr });
        return 1;
    }

    const kp = X25519.KeyPair.generate(io);
    const pk_hex = std.fmt.bytesToHex(kp.public_key, .lower);
    var r = try httpc.postBinary(io, gpa, &addr, "/claim", &pk_hex);
    defer r.deinit(gpa);
    if (r.status != 200) {
        log.err("claim rejected: HTTP {d} {s}", .{ r.status, std.mem.trim(u8, r.body, " \r\n") });
        return 1;
    }
    const board_hex = std.mem.trim(u8, r.body, " \r\n");
    var board_pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&board_pk, board_hex) catch {
        log.err("bad board public key in reply", .{});
        return 1;
    };
    const psk = try auth.derivePsk(kp.secret_key, board_pk);
    const psk_hex = auth.pskToHex(&psk);

    // Save as a drop-in: <config>.d/board-<bdaddr>.conf
    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "psk = {s}={s}\n", .{ info.bdaddr, &psk_hex });
    var fname: [24]u8 = undefined;
    for (info.bdaddr, 0..) |c, i| fname[i] = if (c == ':') '-' else c;
    var path_buf: [512]u8 = undefined;
    const dropin = try std.fmt.bufPrint(&path_buf, "{s}.d/board-{s}.conf", .{ cfg_path, fname[0..17] });

    if (writeFile(io, dropin, line)) {
        log.info("claimed {s} ({s}); key saved to {s}", .{ ip, info.bdaddr, dropin });
        log.info("restart the service so it picks up the key: e.g. `rc-service hcibridged restart`", .{});
    } else |err| {
        log.warn("claimed {s} ({s}) but could not write {s}: {s}", .{ ip, info.bdaddr, dropin, @errorName(err) });
        var obuf: [256]u8 = undefined;
        var out = Io.File.stdout().writer(io, &obuf);
        try out.interface.print("# add this line to {s} (or a .d drop-in):\n{s}", .{ cfg_path, line });
        try out.interface.flush();
    }
    return 0;
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

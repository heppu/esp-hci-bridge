//! One-shot CLI commands: discover bridges, show status, push OTA updates.

const std = @import("std");
const Io = std.Io;
const disc = @import("discovery");
const auth = @import("auth");
const httpc = @import("httpc.zig");
const release = @import("release.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const settings = @import("settings.zig");
const X25519 = std.crypto.dh.X25519;

pub const default_config = "/etc/hcibridge/config";

fn envGet(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
    const env: *const std.process.Environ = @ptrCast(@alignCast(ctx.?));
    return env.getPosix(name);
}

/// Loads psk entries from the config (main + .d) and HCIBRIDGE_PSK. Caller deinit()s.
pub fn loadKeys(io: Io, gpa: std.mem.Allocator, cfg_path: []const u8) !settings.Settings {
    var raw = config.loadRaw(gpa, io, cfg_path) catch |err| blk: {
        log.warn("config {s}: {s} (using defaults)", .{ cfg_path, @errorName(err) });
        break :blk config.Raw{ .arena = std.heap.ArenaAllocator.init(gpa) };
    };
    defer raw.deinit();
    // The process Io is always Io.Threaded (see start.zig), which carries the environ.
    const threaded: *Io.Threaded = @ptrCast(@alignCast(io.userdata));
    var env = threaded.environ.process_environ;
    return settings.resolve(gpa, raw.pairs.items, &.{}, envGet, @ptrCast(&env));
}

/// The key drop-ins are root-only, so a missing key as a normal user usually
/// means "not root", not "not claimed".
fn noKeyHint() []const u8 {
    return if (std.os.linux.getuid() == 0) "run `hcibridge claim <ip>` first" else "the key file is root-only, run this with sudo or doas";
}

const BoardInfo = struct {
    bdaddr: []const u8,
    /// null: firmware before v0.10 (no key support at all)
    claimed: ?bool,
    /// null: firmware before v0.10.3 (replayable proofs, see auth.httpAuthLegacy)
    nonce: ?auth.HttpNonce,
    version_buf: [32]u8 = undefined,
    version_len: usize = 0,
    board_buf: [48]u8 = undefined,
    board_len: usize = 0,

    fn version(self: *const BoardInfo) []const u8 {
        return self.version_buf[0..self.version_len];
    }
    /// null: firmware before v0.10.9, which does not say which preset it is
    fn board(self: *const BoardInfo) ?[]const u8 {
        return if (self.board_len == 0) null else self.board_buf[0..self.board_len];
    }
};

fn boardInfo(io: Io, gpa: std.mem.Allocator, addr: *const Io.net.IpAddress, bdaddr_out: *[17]u8) !BoardInfo {
    var r = try httpc.get(io, gpa, addr, "/");
    defer r.deinit(gpa);
    var buf: [48]u8 = undefined;
    const b = httpc.jsonField(r.body, "bdaddr", &buf) orelse return error.NoBdaddr;
    if (b.len != 17) return error.NoBdaddr;
    @memcpy(bdaddr_out, b);
    var nbuf: [48]u8 = undefined;
    const nonce = if (httpc.jsonField(r.body, "nonce", &nbuf)) |h| auth.hexToNonce(h) else null;
    var info: BoardInfo = .{ .bdaddr = bdaddr_out, .claimed = httpc.jsonBool(r.body, "claimed"), .nonce = nonce };
    var vbuf: [32]u8 = undefined;
    if (httpc.jsonField(r.body, "version", &vbuf)) |v| {
        @memcpy(info.version_buf[0..v.len], v);
        info.version_len = v.len;
    }
    var bbuf: [48]u8 = undefined;
    if (httpc.jsonField(r.body, "board", &bbuf)) |v| {
        @memcpy(info.board_buf[0..v.len], v);
        info.board_len = v.len;
    }
    return info;
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
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = Io.Duration.fromMilliseconds(window_ms), .clock = .awake });
    while (deadline.durationFromNow(io).raw.nanoseconds > 0) {
        const msg = sock.receiveTimeout(io, &rbuf, .{ .deadline = deadline }) catch break;
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
    var u = ui.Ui.init(io);
    const addr: Io.net.IpAddress = .{ .ip4 = try Io.net.Ip4Address.parse(ip, 80) };
    var r = httpc.get(io, gpa, &addr, "/") catch |err| {
        u.fail("cannot reach {s}: {s}", .{ ip, @errorName(err) }, "", .{});
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

/// Both proof headers on one line pair, or the legacy single header for
/// boards that publish no nonce.
fn authHeaders(psk: *const auth.Psk, method: []const u8, path: []const u8, nonce: ?auth.HttpNonce, body: []const u8, out: *[160]u8) []const u8 {
    var mac: [auth.mac_len * 2]u8 = undefined;
    if (nonce) |n| {
        var pre: [auth.mac_len * 2]u8 = undefined;
        _ = auth.httpAuth(psk, method, path, &n, body, &mac);
        _ = auth.httpPre(psk, method, path, &n, @intCast(body.len), &pre);
        return std.fmt.bufPrint(out, "X-Bridge-Auth: {s}\r\nX-Bridge-Pre: {s}", .{ &mac, &pre }) catch unreachable;
    }
    _ = auth.httpAuthLegacy(psk, method, path, body, &mac);
    return std.fmt.bufPrint(out, "X-Bridge-Auth: {s}", .{&mac}) catch unreachable;
}

fn onUpload(ctx: *anyopaque, sent: usize) void {
    const bar: *ui.Progress = @ptrCast(@alignCast(ctx));
    bar.update(sent);
}

fn updateOne(io: Io, gpa: std.mem.Allocator, u: *ui.Ui, addr: *const Io.net.IpAddress, image: []const u8, keys: *const settings.Settings) bool {
    var bd: [17]u8 = undefined;
    var ipb: [48]u8 = undefined;
    const ip = ui.ipOf(addr, &ipb);
    u.step("Board {s}", .{ip});
    const info = boardInfo(io, gpa, addr, &bd) catch |err| {
        u.fail("board {s} did not answer: {s}", .{ ip, ui.explain(err) }, "is it powered and on this network? `hcibridge list` shows what is visible", .{});
        return false;
    };
    u.done("{s}, {s}, running {s}", .{ info.bdaddr, info.board() orelse "unknown board type", info.version() });
    // Firmware before v0.10 reports no claim state and takes unauthenticated
    // uploads, which is the only way to move such a board onto keyed firmware.
    var hbuf: [160]u8 = undefined;
    var hdr: ?[]const u8 = null;
    if (info.claimed != null) {
        const psk = settings.lookupPsk(keys.psk, info.bdaddr) orelse {
            u.fail("no key for {s}", .{info.bdaddr}, "{s}", .{noKeyHint()});
            return false;
        };
        hdr = authHeaders(&psk, "POST", "/ota", info.nonce, image, &hbuf);
    } else u.warn("{s} runs firmware from before keys existed, sending the update unauthenticated", .{ip});
    var bar = u.progress("Uploading to {s}", .{ip}, image.len);
    var r = httpc.postProgress(io, gpa, addr, "/ota", image, hdr, onUpload, @ptrCast(&bar)) catch |err| {
        bar.finish(0);
        u.fail("upload to {s} failed: {s}", .{ ip, ui.explain(err) }, "", .{});
        return false;
    };
    defer r.deinit(gpa);
    bar.finish(image.len);
    if (r.status != 200) {
        const hint: []const u8 = switch (r.status) {
            401, 403 => "the key on this PC does not match the board, run `hcibridge claim` again or check /etc/hcibridge/config.d",
            413 => "the image is larger than the board's firmware partition",
            else => "",
        };
        u.fail("board {s} rejected the image: HTTP {d} {s}", .{ ip, r.status, std.mem.trim(u8, r.body, " \r\n") }, "{s}", .{hint});
        return false;
    }
    u.info("Board accepted the image and is rebooting", .{});
    waitForBoard(io, gpa, u, addr, info.version());
    return true;
}

/// Polls the board after an OTA until it answers again, then says what it runs.
fn waitForBoard(io: Io, gpa: std.mem.Allocator, u: *ui.Ui, addr: *const Io.net.IpAddress, old_version: []const u8) void {
    u.step("Waiting for it to come back", .{});
    const start = Io.Clock.Timestamp.now(io, .awake);
    io.sleep(Io.Duration.fromMilliseconds(3000), .awake) catch {};
    while (start.untilNow(io).raw.toMilliseconds() < 90_000) {
        var bd: [17]u8 = undefined;
        if (boardInfo(io, gpa, addr, &bd)) |info| {
            const secs = @divTrunc(start.untilNow(io).raw.toMilliseconds(), 1000);
            u.done("up after {d} s, running {s}", .{ secs, info.version() });
            if (std.mem.eql(u8, info.version(), old_version)) {
                u.warn("same version as before, the new image may have failed to boot and rolled back", .{});
                var ipb: [48]u8 = undefined;
                u.info("  `hcibridge status {s}` shows prev_stage (how far it got) and reset (why it stopped)", .{ui.ipOf(addr, &ipb)});
            }
            return;
        } else |_| {}
        io.sleep(Io.Duration.fromMilliseconds(1000), .awake) catch {};
    }
    u.done("no answer after 90 s", .{});
    u.warn("the board did not come back yet, check `hcibridge list` in a minute", .{});
}

/// Images for the latest release, fetched once per board preset.
const LatestImages = struct {
    client: std.http.Client,
    rel: release.Latest,
    cache: std.StringHashMap([]u8),
    gpa: std.mem.Allocator,

    fn init(io: Io, gpa: std.mem.Allocator, u: *ui.Ui) !LatestImages {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        errdefer client.deinit();
        u.step("Checking the latest release of {s}", .{release.repo});
        const rel = release.latest(&client, gpa) catch |err| {
            u.done("failed", .{});
            return err;
        };
        u.done("{s}", .{rel.tag});
        return .{ .client = client, .rel = rel, .cache = std.StringHashMap([]u8).init(gpa), .gpa = gpa };
    }

    fn deinit(self: *LatestImages) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.cache.deinit();
        self.rel.deinit();
        self.client.deinit();
    }

    fn image(self: *LatestImages, u: *ui.Ui, board: []const u8) ![]const u8 {
        if (self.cache.get(board)) |img| return img;
        const img = try self.rel.image(&self.client, self.gpa, board, u);
        errdefer self.gpa.free(img);
        u.info("Checksum ok", .{});
        const key = try self.gpa.dupe(u8, board);
        errdefer self.gpa.free(key);
        try self.cache.put(key, img);
        return img;
    }
};

/// Picks the image for one board: the given file, or the latest release for
/// the board's preset. Returns null when the board is already on that release.
fn imageFor(io: Io, gpa: std.mem.Allocator, u: *ui.Ui, addr: *const Io.net.IpAddress, file_image: ?[]const u8, latest_images: *?LatestImages, board_override: ?[]const u8) !?[]const u8 {
    if (file_image) |img| return img;
    var bd: [17]u8 = undefined;
    var ipb: [48]u8 = undefined;
    const ip = ui.ipOf(addr, &ipb);
    const info = boardInfo(io, gpa, addr, &bd) catch |err| {
        u.fail("board {s} did not answer: {s}", .{ ip, ui.explain(err) }, "is it powered and on this network? `hcibridge list` shows what is visible", .{});
        return error.Reported;
    };
    const board = board_override orelse info.board() orelse {
        u.fail("{s} runs firmware that does not say which board it is", .{ip}, "pass --board <preset> (olimex-esp32-poe, wt32-eth01, generic-wifi) or a firmware file", .{});
        return error.Reported;
    };
    if (latest_images.* == null) latest_images.* = LatestImages.init(io, gpa, u) catch |err| {
        u.fail("could not reach the release page: {s}", .{ui.explain(err)}, "check the network, or pass a firmware file downloaded by other means", .{});
        return error.Reported;
    };
    const li = &latest_images.*.?;
    if (std.mem.eql(u8, info.version(), li.rel.tag)) {
        u.info("{s} ({s}) already runs {s}, nothing to do", .{ ip, board, li.rel.tag });
        return null;
    }
    return li.image(u, board) catch |err| {
        u.fail("could not fetch the {s} image for {s}: {s}", .{ li.rel.tag, board, ui.explain(err) }, "", .{});
        return error.Reported;
    };
}

pub fn update(io: Io, gpa: std.mem.Allocator, target: []const u8, path: ?[]const u8, board_override: ?[]const u8, discovery_port: u16, cfg_path: []const u8) !u8 {
    var u = ui.Ui.init(io);
    const file_image: ?[]const u8 = if (path) |p| readFile(io, gpa, p) catch |err| {
        u.fail("cannot read {s}: {s}", .{ p, ui.explain(err) }, "", .{});
        return 1;
    } else null;
    defer if (file_image) |img| gpa.free(img);
    var latest_images: ?LatestImages = null;
    defer if (latest_images) |*li| li.deinit();
    var keys = try loadKeys(io, gpa, cfg_path);
    defer keys.deinit();

    if (std.mem.eql(u8, target, "all")) {
        u.step("Looking for boards", .{});
        const bridges = try collect(io, gpa, discovery_port, 2500);
        defer gpa.free(bridges);
        u.done("{d} found", .{bridges.len});
        if (bridges.len == 0) {
            u.fail("no boards answered on the network", .{}, "`hcibridge list` uses the same discovery, boards must be on this LAN and powered", .{});
            return 1;
        }
        var ok: usize = 0;
        for (bridges) |*b| {
            var a = b.addr;
            a.setPort(80);
            const img = (imageFor(io, gpa, &u, &a, file_image, &latest_images, board_override) catch continue) orelse {
                ok += 1;
                continue;
            };
            if (updateOne(io, gpa, &u, &a, img, &keys)) ok += 1;
        }
        u.info("{d} of {d} boards up to date", .{ ok, bridges.len });
        return if (ok == bridges.len) 0 else 1;
    }

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(target, 80) catch {
        u.fail("{s} is not an IPv4 address", .{target}, "give a board address from `hcibridge list`, or `all`", .{});
        return 2;
    } };
    const img = (imageFor(io, gpa, &u, &addr, file_image, &latest_images, board_override) catch return 1) orelse return 0;
    return if (updateOne(io, gpa, &u, &addr, img, &keys)) 0 else 1;
}

fn dropinPath(cfg_path: []const u8, bdaddr: []const u8, buf: *[512]u8) ![]const u8 {
    var fname: [17]u8 = undefined;
    for (bdaddr[0..17], 0..) |c, i| fname[i] = if (c == ':') '-' else std.ascii.toLower(c);
    return std.fmt.bufPrint(buf, "{s}.d/board-{s}.conf", .{ cfg_path, &fname });
}

/// Removes a board's key from the config. The running daemon notices on the
/// board's next announce and drops its link. The board itself keeps thinking
/// it is claimed, which only matters if it should pair with another PC.
pub fn revoke(io: Io, gpa: std.mem.Allocator, bdaddr: []const u8, cfg_path: []const u8) !u8 {
    var u = ui.Ui.init(io);
    if (bdaddr.len != 17) {
        u.fail("expected a Bluetooth address like a0:a3:b3:2f:61:1e, got {s}", .{bdaddr}, "", .{});
        return 2;
    }
    var path_buf: [512]u8 = undefined;
    const dropin = try dropinPath(cfg_path, bdaddr, &path_buf);
    Io.Dir.cwd().deleteFile(io, dropin) catch |err| switch (err) {
        error.FileNotFound => {
            var keys = try loadKeys(io, gpa, cfg_path);
            defer keys.deinit();
            if (settings.lookupPsk(keys.psk, bdaddr) != null) {
                u.fail("{s} has no drop-in at {s} but a key is set elsewhere: remove the `psk = {s}=...` line from {s} or its .d files by hand", .{ bdaddr, dropin, bdaddr, cfg_path }, "", .{});
                return 1;
            }
            u.info("{s} is not claimed on this PC, nothing to do", .{bdaddr});
            return 0;
        },
        else => {
            u.fail("cannot remove {s}: {s}", .{ dropin, @errorName(err) }, "", .{});
            return 1;
        },
    };
    u.info("revoked {s}: removed {s}; the daemon drops the board on its next announce", .{ bdaddr, dropin });
    return 0;
}

pub fn reboot(io: Io, gpa: std.mem.Allocator, ip: []const u8, cfg_path: []const u8) !u8 {
    var u = ui.Ui.init(io);
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(ip, httpc.http_port) catch {
        u.fail("bad ip: {s}", .{ip}, "", .{});
        return 2;
    } };
    var keys = try loadKeys(io, gpa, cfg_path);
    defer keys.deinit();
    var bd: [17]u8 = undefined;
    const info = try boardInfo(io, gpa, &addr, &bd);
    const psk = settings.lookupPsk(keys.psk, info.bdaddr) orelse {
        u.fail("no key for {s}", .{info.bdaddr}, "{s}", .{noKeyHint()});
        return 1;
    };
    var hbuf: [160]u8 = undefined;
    const hdr = authHeaders(&psk, "POST", "/reboot", info.nonce, "", &hbuf);
    var r = try httpc.postH(io, gpa, &addr, "/reboot", "", hdr);
    defer r.deinit(gpa);
    if (r.status != 200) {
        u.fail("reboot rejected: HTTP {d}", .{r.status}, "", .{});
        return 1;
    }
    u.info("{s} rebooting", .{ip});
    return 0;
}

/// Tells a board to forget its key and reboot unclaimed, then removes the key
/// on this side too. Requires the current key, so only the owning PC can do it.
pub fn unclaim(io: Io, gpa: std.mem.Allocator, ip: []const u8, cfg_path: []const u8) !u8 {
    var u = ui.Ui.init(io);
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(ip, httpc.http_port) catch {
        u.fail("bad ip: {s}", .{ip}, "", .{});
        return 2;
    } };
    var keys = try loadKeys(io, gpa, cfg_path);
    defer keys.deinit();
    var bd: [17]u8 = undefined;
    const info = try boardInfo(io, gpa, &addr, &bd);
    if (info.claimed == false) {
        u.info("{s} ({s}) is not claimed by anyone", .{ ip, info.bdaddr });
        return revoke(io, gpa, info.bdaddr, cfg_path);
    }
    const psk = settings.lookupPsk(keys.psk, info.bdaddr) orelse {
        u.fail("no key for {s}: this PC did not claim it, so it cannot release it (erase the board over USB instead)", .{info.bdaddr}, "", .{});
        return 1;
    };
    var hbuf: [160]u8 = undefined;
    const hdr = authHeaders(&psk, "POST", "/unclaim", info.nonce, "", &hbuf);
    var r = try httpc.postH(io, gpa, &addr, "/unclaim", "", hdr);
    defer r.deinit(gpa);
    if (r.status == 404) {
        u.fail("{s} runs firmware without unclaim support: run `hcibridge update {s} <hcibridge-<board>.bin>` first", .{ ip, ip }, "", .{});
        return 1;
    }
    if (r.status != 200) {
        u.fail("unclaim rejected: HTTP {d} {s}", .{ r.status, std.mem.trim(u8, r.body, " \r\n") }, "", .{});
        return 1;
    }
    u.info("{s} ({s}) forgot its key and is rebooting unclaimed", .{ ip, info.bdaddr });
    return revoke(io, gpa, info.bdaddr, cfg_path);
}

/// Pairs with an unclaimed board: X25519 exchange, PSK = SHA256(shared),
/// written as a drop-in under <config>.d/. First claim wins; re-keying needs
/// a factory reset of the board.
pub fn claim(io: Io, gpa: std.mem.Allocator, ip: []const u8, cfg_path: []const u8) !u8 {
    var u = ui.Ui.init(io);
    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.parse(ip, httpc.http_port) catch {
        u.fail("bad ip: {s}", .{ip}, "", .{});
        return 2;
    } };
    var bd: [17]u8 = undefined;
    const info = try boardInfo(io, gpa, &addr, &bd);
    const claimed = info.claimed orelse {
        u.fail("{s} ({s}) runs firmware without key support: update it first.", .{ ip, info.bdaddr }, "", .{});
        return 1;
    };
    if (claimed) {
        u.fail("{s} ({s}) is already claimed. To re-key it, factory-reset the board first.", .{ ip, info.bdaddr }, "", .{});
        return 1;
    }

    const kp = X25519.KeyPair.generate(io);
    const pk_hex = std.fmt.bytesToHex(kp.public_key, .lower);
    var r = try httpc.postBinary(io, gpa, &addr, "/claim", &pk_hex);
    defer r.deinit(gpa);
    if (r.status != 200) {
        u.fail("claim rejected: HTTP {d} {s}", .{ r.status, std.mem.trim(u8, r.body, " \r\n") }, "", .{});
        return 1;
    }
    const board_hex = std.mem.trim(u8, r.body, " \r\n");
    var board_pk: [32]u8 = undefined;
    if (board_hex.len != board_pk.len * 2) {
        u.fail("bad board public key in reply: {d} chars, want 64", .{board_hex.len}, "", .{});
        return 1;
    }
    _ = std.fmt.hexToBytes(&board_pk, board_hex) catch {
        u.fail("bad board public key in reply", .{}, "", .{});
        return 1;
    };
    const psk = try auth.derivePsk(kp.secret_key, board_pk);
    const psk_hex = auth.pskToHex(&psk);

    // Save as a drop-in: <config>.d/board-<bdaddr>.conf
    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "psk = {s}={s}\n", .{ info.bdaddr, &psk_hex });
    var path_buf: [512]u8 = undefined;
    const dropin = try dropinPath(cfg_path, info.bdaddr, &path_buf);

    if (writeFile(io, dropin, line)) {
        u.info("claimed {s} ({s}); key saved to {s}", .{ ip, info.bdaddr, dropin });
        u.info("the running daemon picks the key up on the board's next announce", .{});
    } else |err| {
        u.warn("claimed {s} ({s}) but could not write {s}: {s}", .{ ip, info.bdaddr, dropin, @errorName(err) });
        var obuf: [256]u8 = undefined;
        var out = Io.File.stdout().writer(io, &obuf);
        try out.interface.print("# add this line to {s} (or a .d drop-in):\n{s}", .{ cfg_path, line });
        try out.interface.flush();
        return 3;
    }
    return 0;
}

/// Writes a secret: created 0600, and re-chmodded in case the file already existed.
fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    const mode: Io.File.Permissions = .fromMode(0o600);
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = mode });
    defer f.close(io);
    try f.setPermissions(io, mode);
    try f.writeStreamingAll(io, data);
}

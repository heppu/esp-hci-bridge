//! Discovery manager: finds ESP HCI bridges by UDP broadcast and gives each
//! its own vhci adapter. Plug and play, many boards at once.

const std = @import("std");
const Io = std.Io;
const disc = @import("discovery");
const auth = @import("auth");
const settings = @import("settings.zig");
const board = @import("board.zig");

const log = std.log.scoped(.manager);

pub const Options = struct {
    discovery_port: u16 = disc.default_port,
    vhci_path: []const u8 = "/dev/vhci",
    probe_interval_ms: u32 = 5000,
    bind: []const u8 = "0.0.0.0",
    subnet: []const u8 = "",
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    /// "bdaddr=hex" entries from `hcibridge claim`. Boards without one are
    /// never attached.
    psk_entries: []const []const u8 = &.{},
    /// Re-reads the config so a fresh `hcibridge claim` is picked up without a restart.
    reload_keys: ?*const fn (io: Io, gpa: std.mem.Allocator, cfg_path: []const u8) anyerror!settings.Settings = null,
    cfg_path: []const u8 = "",
    /// Hosts served by pinned client threads, their announces are ignored.
    pinned: []const []const u8 = &.{},
};

const max_warned = 256;

const Keys = struct {
    entries: []const []const u8,
    loaded: ?settings.Settings = null,
    last: ?Io.Clock.Timestamp = null,

    /// At most one config re-read per 2 s, so a flood of unknown boards cannot
    /// turn into a flood of disk reads.
    fn refresh(self: *Keys, io: Io, gpa: std.mem.Allocator, opts: *const Options) bool {
        const reload = opts.reload_keys orelse return false;
        if (self.last) |t| if (t.untilNow(io).raw.toMilliseconds() < 2000) return false;
        self.last = Io.Clock.Timestamp.now(io, .awake);
        var fresh = reload(io, gpa, opts.cfg_path) catch |err| {
            log.warn("config reload failed: {s}", .{@errorName(err)});
            return false;
        };
        if (self.loaded) |*old| old.deinit();
        self.loaded = fresh;
        self.entries = fresh.psk;
        _ = &fresh;
        return true;
    }

    fn deinit(self: *Keys) void {
        if (self.loaded) |*l| l.deinit();
    }
};

const Cidr = struct {
    base: u32,
    mask: u32,
    fn parse(text: []const u8) ?Cidr {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
        const ip = Io.net.Ip4Address.parse(text[0..slash], 0) catch return null;
        const bits = std.fmt.parseInt(u6, text[slash + 1 ..], 10) catch return null;
        if (bits > 32) return null;
        const mask: u32 = if (bits == 0) 0 else @as(u32, 0xffffffff) << @intCast(32 - bits);
        return .{ .base = std.mem.readInt(u32, &ip.bytes, .big), .mask = mask };
    }
    fn contains(self: Cidr, ip: [4]u8) bool {
        const v = std.mem.readInt(u32, &ip, .big);
        return (v & self.mask) == (self.base & self.mask);
    }
};

fn permits(opts: Options, bdaddr: []const u8) bool {
    for (opts.deny) |d| if (std.ascii.eqlIgnoreCase(d, bdaddr)) return false;
    if (opts.allow.len == 0) return true;
    for (opts.allow) |a| if (std.ascii.eqlIgnoreCase(a, bdaddr)) return true;
    return false;
}

const Active = struct {
    mutex: Io.Mutex = .init,
    map: std.StringHashMap(*BoardCtx),
    io: Io,

    fn init(gpa: std.mem.Allocator, io: Io) Active {
        return .{ .map = std.StringHashMap(*BoardCtx).init(gpa), .io = io };
    }

    /// Returns true if newly claimed. A board back from another address gets its old link killed.
    fn claim(self: *Active, ctx: *BoardCtx) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.get(ctx.bdaddr)) |old| {
            if (!std.mem.eql(u8, &old.ip, &ctx.ip)) {
                log.info("{s} ({s}) reappeared at {f}, was {f}, dropping the old link", .{ ctx.name, ctx.bdaddr, ctx.addr, old.addr });
                old.link.kill(self.io);
            }
            return false;
        }
        self.map.put(ctx.bdaddr, ctx) catch return false;
        return true;
    }

    fn release(self: *Active, bdaddr: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.map.remove(bdaddr);
    }
};

const BoardCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    active: *Active,
    addr: Io.net.IpAddress,
    ip: [4]u8,
    bdaddr: []u8,
    name: []u8,
    vhci_path: []const u8,
    psk: auth.Psk,
    link: board.Link = .{},

    fn destroy(ctx: *BoardCtx) void {
        ctx.gpa.free(ctx.bdaddr);
        ctx.gpa.free(ctx.name);
        ctx.gpa.destroy(ctx);
    }
};

fn boardThread(ctx: *BoardCtx) void {
    const backoff_ms: u32 = if (board.run(ctx.io, &ctx.addr, ctx.vhci_path, ctx.name, &ctx.psk, &ctx.link)) |_| 500 else |err| switch (err) {
        error.AuthFailed => blk: {
            log.warn("[{s}] session ended: {s}", .{ ctx.name, @errorName(err) });
            break :blk 5000;
        },
        error.VhciOpen => blk: {
            log.err("[{s}] cannot open {s}: load the hci_vhci module and run as root, retrying in 10 s", .{ ctx.name, ctx.vhci_path });
            break :blk 10_000;
        },
        else => blk: {
            log.warn("[{s}] session ended: {s}", .{ ctx.name, @errorName(err) });
            break :blk 500;
        },
    };
    // Back off while still claimed so a flapping board cannot start a second session.
    ctx.io.sleep(Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
    ctx.active.release(ctx.bdaddr);
    ctx.destroy();
}

fn isPinned(pinned: []const [4]u8, ip: [4]u8) bool {
    for (pinned) |p| if (std.mem.eql(u8, &p, &ip)) return true;
    return false;
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    var active = Active.init(gpa, io);
    defer active.map.deinit();
    // Unclaimed boards are logged once each, not every 2 s.
    var keys: Keys = .{ .entries = opts.psk_entries };
    defer keys.deinit();
    var warned = std.StringHashMap(void).init(gpa);
    defer {
        var it = warned.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        warned.deinit();
    }

    const bind_ip = Io.net.Ip4Address.parse(opts.bind, opts.discovery_port) catch |err| {
        log.err("bad bind address {s}: {s}", .{ opts.bind, @errorName(err) });
        return error.BadBindAddress;
    };
    const subnet: ?Cidr = if (opts.subnet.len == 0) null else Cidr.parse(opts.subnet) orelse {
        log.err("bad subnet {s}: want a.b.c.d/bits", .{opts.subnet});
        return error.BadSubnet;
    };

    var pinned: std.ArrayList([4]u8) = .empty;
    defer pinned.deinit(gpa);
    for (opts.pinned) |host| {
        const addr = Io.net.IpAddress.resolve(io, host, 0) catch |err| {
            log.warn("pinned board {s}: {s}, discovery may attach it a second time", .{ host, @errorName(err) });
            continue;
        };
        switch (addr) {
            .ip4 => |v4| try pinned.append(gpa, v4.bytes),
            else => {},
        }
    }

    const bind_addr: Io.net.IpAddress = .{ .ip4 = bind_ip };
    const sock = try bind_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer sock.close(io);
    log.info("discovery listening on udp {d}, probing for bridges", .{opts.discovery_port});
    if (!std.mem.eql(u8, &bind_ip.bytes, &.{ 0, 0, 0, 0 })) {
        log.warn("bound to {s}: broadcast announces are not delivered to a unicast bind, boards are found by probe replies only", .{opts.bind});
    }

    const bcast: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = opts.discovery_port } };
    var probe_buf: [64]u8 = undefined;
    const probe = disc.buildProbe(&probe_buf);

    var rbuf: [disc.max_datagram]u8 = undefined;
    // Probe on startup, then roughly every few seconds while idle. Boards also
    // announce on their own, so probing just speeds up first contact.
    sock.send(io, &bcast, probe) catch |err| log.debug("probe send: {s}", .{@errorName(err)});
    const probe_every = @max(@as(u32, 1), opts.probe_interval_ms / 1000);
    var idle_ticks: u32 = 0;

    while (true) {
        const msg = sock.receiveTimeout(io, &rbuf, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(1000), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {
                idle_ticks += 1;
                if (idle_ticks >= probe_every) {
                    idle_ticks = 0;
                    sock.send(io, &bcast, probe) catch |e| log.debug("probe send: {s}", .{@errorName(e)});
                }
                continue;
            },
            else => {
                log.warn("discovery recv: {s}", .{@errorName(err)});
                continue;
            },
        };

        const parsed = disc.parse(msg.data) catch continue;
        const ann = switch (parsed) {
            .announce => |a| a,
            .probe => continue, // another host probing, ignore
        };

        if (!permits(opts, ann.bdaddr)) continue;
        const from_ip: [4]u8 = switch (msg.from) {
            .ip4 => |v4| v4.bytes,
            else => continue,
        };
        if (isPinned(pinned.items, from_ip)) continue;

        // Only boards we hold a key for, and only announces they signed.
        const psk = settings.lookupPsk(keys.entries, ann.bdaddr) orelse
            (if (keys.refresh(io, gpa, &opts)) settings.lookupPsk(keys.entries, ann.bdaddr) else null) orelse
            {
                if (!warned.contains(ann.bdaddr)) {
                    if (warned.count() >= max_warned) {
                        var it = warned.keyIterator();
                        while (it.next()) |k| gpa.free(k.*);
                        warned.clearRetainingCapacity();
                    }
                    if (gpa.dupe(u8, ann.bdaddr)) |k| warned.put(k, {}) catch gpa.free(k) else |_| {}
                    var abuf: [24]u8 = undefined;
                    const astr = std.fmt.bufPrint(&abuf, "{f}", .{msg.from}) catch "?";
                    log.warn("ignoring unclaimed board {s} ({s}) at {s}: run `hcibridge claim <ip>` to pair it", .{ ann.name, ann.bdaddr, astr });
                }
                continue;
            };
        var verified = auth.verifyAnnounce(&psk, ann.bdaddr, ann.port, ann.name, from_ip, ann.sig);
        if (!verified and keys.refresh(io, gpa, &opts)) {
            if (settings.lookupPsk(keys.entries, ann.bdaddr)) |fresh| {
                verified = auth.verifyAnnounce(&fresh, ann.bdaddr, ann.port, ann.name, from_ip, ann.sig);
            }
        }
        if (!verified) {
            log.warn("ignoring announce for {s} with a bad signature (spoofed, replayed, or stale key)", .{ann.bdaddr});
            continue;
        }
        if (subnet) |cidr| if (!cidr.contains(from_ip)) continue;

        var addr = msg.from;
        addr.setPort(ann.port);

        const ctx = gpa.create(BoardCtx) catch continue;
        ctx.* = .{
            .io = io,
            .gpa = gpa,
            .active = &active,
            .addr = addr,
            .ip = from_ip,
            .bdaddr = gpa.dupe(u8, ann.bdaddr) catch {
                gpa.destroy(ctx);
                continue;
            },
            .name = gpa.dupe(u8, ann.name) catch {
                gpa.free(ctx.bdaddr);
                gpa.destroy(ctx);
                continue;
            },
            .vhci_path = opts.vhci_path,
            .psk = psk,
        };
        if (!active.claim(ctx)) {
            ctx.destroy();
            continue;
        }
        log.info("discovered {s} ({s}) at {f}", .{ ann.name, ann.bdaddr, addr });

        const t = std.Thread.spawn(.{}, boardThread, .{ctx}) catch |err| {
            log.err("cannot spawn board thread: {s}", .{@errorName(err)});
            active.release(ctx.bdaddr);
            ctx.destroy();
            continue;
        };
        t.detach();
    }
}

const testing = std.testing;

test "cidr parse accepts every prefix length" {
    const any = Cidr.parse("0.0.0.0/0").?;
    try testing.expectEqual(@as(u32, 0), any.mask);
    const eight = Cidr.parse("10.0.0.0/8").?;
    try testing.expectEqual(@as(u32, 0xff000000), eight.mask);
    try testing.expectEqual(@as(u32, 0x0a000000), eight.base);
    const c = Cidr.parse("192.168.1.0/24").?;
    try testing.expectEqual(@as(u32, 0xffffff00), c.mask);
    const host = Cidr.parse("172.16.135.242/32").?;
    try testing.expectEqual(@as(u32, 0xffffffff), host.mask);
    try testing.expectEqual(@as(u32, 0xac1087f2), host.base);
}

test "cidr parse rejects malformed input" {
    try testing.expect(Cidr.parse("10.0.0.0") == null);
    try testing.expect(Cidr.parse("10.0.0.0/") == null);
    try testing.expect(Cidr.parse("10.0.0.0/33") == null);
    try testing.expect(Cidr.parse("10.0.0.0/-1") == null);
    try testing.expect(Cidr.parse("10.0.0.0/x") == null);
    try testing.expect(Cidr.parse("/24") == null);
    try testing.expect(Cidr.parse("10.0.0/24") == null);
    try testing.expect(Cidr.parse("garbage") == null);
    try testing.expect(Cidr.parse("") == null);
}

test "cidr contains" {
    const lan = Cidr.parse("192.168.1.0/24").?;
    try testing.expect(lan.contains(.{ 192, 168, 1, 77 }));
    try testing.expect(lan.contains(.{ 192, 168, 1, 0 }));
    try testing.expect(!lan.contains(.{ 192, 168, 2, 1 }));
    const any = Cidr.parse("0.0.0.0/0").?;
    try testing.expect(any.contains(.{ 8, 8, 8, 8 }));
    const one = Cidr.parse("10.1.2.3/32").?;
    try testing.expect(one.contains(.{ 10, 1, 2, 3 }));
    try testing.expect(!one.contains(.{ 10, 1, 2, 4 }));
    // Base bits below the mask are ignored, so 10.1.2.3/8 behaves like 10.0.0.0/8.
    const sloppy = Cidr.parse("10.1.2.3/8").?;
    try testing.expect(sloppy.contains(.{ 10, 200, 0, 1 }));
}

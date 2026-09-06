//! Discovery manager: finds ESP HCI bridges by UDP broadcast and gives each
//! its own vhci adapter. Plug and play, many boards at once.

const std = @import("std");
const Io = std.Io;
const disc = @import("discovery");
const board = @import("board.zig");

const log = std.log.scoped(.manager);

pub const Options = struct {
    discovery_port: u16 = disc.default_port,
    vhci_path: []const u8 = "/dev/vhci",
    probe_interval_ms: u32 = 5000,
};

const Active = struct {
    mutex: Io.Mutex = .init,
    set: std.StringHashMap(void),
    gpa: std.mem.Allocator,
    io: Io,

    fn init(gpa: std.mem.Allocator, io: Io) Active {
        return .{ .set = std.StringHashMap(void).init(gpa), .gpa = gpa, .io = io };
    }

    /// Returns true if newly claimed (caller owns handling this bdaddr).
    fn claim(self: *Active, bdaddr: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.set.contains(bdaddr)) return false;
        const key = self.gpa.dupe(u8, bdaddr) catch return false;
        self.set.put(key, {}) catch {
            self.gpa.free(key);
            return false;
        };
        return true;
    }

    fn release(self: *Active, bdaddr: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.set.fetchRemove(bdaddr)) |kv| self.gpa.free(kv.key);
    }
};

const BoardCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    active: *Active,
    addr: Io.net.IpAddress,
    bdaddr: []u8,
    name: []u8,
    vhci_path: []const u8,
};

fn boardThread(ctx: *BoardCtx) void {
    _ = board.run(ctx.io, &ctx.addr, ctx.vhci_path, ctx.name) catch |err| {
        log.warn("[{s}] session ended: {s}", .{ ctx.name, @errorName(err) });
    };
    ctx.active.release(ctx.bdaddr);
    // Small settle so we do not thrash if the board is flapping.
    ctx.io.sleep(Io.Duration.fromMilliseconds(500), .awake) catch {};
    ctx.gpa.free(ctx.bdaddr);
    ctx.gpa.free(ctx.name);
    ctx.gpa.destroy(ctx);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    var active = Active.init(gpa, io);

    const bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(opts.discovery_port) };
    const sock = try bind_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer sock.close(io);
    log.info("discovery listening on udp {d}, probing for bridges", .{opts.discovery_port});

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

        if (!active.claim(ann.bdaddr)) continue;

        var addr = msg.from;
        addr.setPort(ann.port);
        log.info("discovered {s} ({s}) at {f}", .{ ann.name, ann.bdaddr, addr });

        const ctx = gpa.create(BoardCtx) catch {
            active.release(ann.bdaddr);
            continue;
        };
        ctx.* = .{
            .io = io,
            .gpa = gpa,
            .active = &active,
            .addr = addr,
            .bdaddr = gpa.dupe(u8, ann.bdaddr) catch {
                active.release(ann.bdaddr);
                gpa.destroy(ctx);
                continue;
            },
            .name = gpa.dupe(u8, ann.name) catch {
                active.release(ann.bdaddr);
                gpa.free(ctx.bdaddr);
                gpa.destroy(ctx);
                continue;
            },
            .vhci_path = opts.vhci_path,
        };

        const t = std.Thread.spawn(.{}, boardThread, .{ctx}) catch |err| {
            log.err("cannot spawn board thread: {s}", .{@errorName(err)});
            active.release(ann.bdaddr);
            gpa.free(ctx.bdaddr);
            gpa.free(ctx.name);
            gpa.destroy(ctx);
            continue;
        };
        t.detach();
    }
}

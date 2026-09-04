//! One bridge session: pumps HCI packets between a TCP stream and a local
//! packet oriented endpoint (the kernel vhci device, or a seqpacket socket
//! in tests).

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const h4 = @import("h4");

const log = std.log.scoped(.session);

/// Local packet endpoint. Reads return exactly one packet, writes carry
/// exactly one packet.
pub const PacketEnd = union(enum) {
    file: Io.File,
    socket: Io.net.Stream,

    fn handle(self: PacketEnd) posix.fd_t {
        return switch (self) {
            .file => |f| f.handle,
            .socket => |s| s.socket.handle,
        };
    }

    fn readPacket(self: PacketEnd, io: Io, buf: []u8) !usize {
        switch (self) {
            .file => |f| return f.readStreaming(io, &.{buf}),
            .socket => |s| {
                var r = s.reader(io, &.{});
                var vec = [_][]u8{buf};
                return r.interface.readVec(&vec);
            },
        }
    }

    fn writePacket(self: PacketEnd, io: Io, pkt: []const u8) !void {
        switch (self) {
            .file => |f| try f.writeStreamingAll(io, pkt),
            .socket => |s| {
                var w = s.writer(io, &.{});
                try w.interface.writeAll(pkt);
                try w.interface.flush();
            },
        }
    }
};

pub const Stats = struct {
    to_controller: u64 = 0,
    to_host: u64 = 0,
};

pub const Session = struct {
    io: Io,
    tcp: Io.net.Stream,
    local: PacketEnd,
    stop: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},
    first_error: ?anyerror = null,

    pub fn init(io: Io, tcp: Io.net.Stream, local: PacketEnd) Session {
        return .{ .io = io, .tcp = tcp, .local = local };
    }

    /// Runs both directions until either side fails or closes. Returns the
    /// packet counters. A clean remote close is not an error.
    pub fn run(self: *Session) !Stats {
        var to_local = try self.io.concurrent(pumpTcpToLocal, .{self});
        var to_tcp = try self.io.concurrent(pumpLocalToTcp, .{self});
        to_local.await(self.io);
        to_tcp.await(self.io);
        if (self.first_error) |err| return err;
        return self.stats;
    }

    fn fail(self: *Session, err: anyerror) void {
        if (self.first_error == null and err != error.EndOfStream and err != error.ConnectionResetByPeer) {
            self.first_error = err;
        }
        self.shutdown();
    }

    fn shutdown(self: *Session) void {
        self.stop.store(true, .release);
        // Wakes the blocked TCP reader. The local reader polls `stop`.
        self.tcp.shutdown(self.io, .both) catch {};
    }

    fn pumpTcpToLocal(self: *Session) void {
        self.tcpToLocal() catch |err| {
            log.debug("tcp->local: {s}", .{@errorName(err)});
            self.fail(err);
            return;
        };
        self.shutdown();
    }

    fn pumpLocalToTcp(self: *Session) void {
        self.localToTcp() catch |err| {
            log.debug("local->tcp: {s}", .{@errorName(err)});
            self.fail(err);
            return;
        };
        self.shutdown();
    }

    fn tcpToLocal(self: *Session) !void {
        var read_buf: [4096]u8 = undefined;
        var pkt_storage: [h4.max_packet_len]u8 = undefined;
        var re = h4.Reassembler.init(&pkt_storage);
        var reader = self.tcp.reader(self.io, &read_buf);
        const r = &reader.interface;

        while (!self.stop.load(.acquire)) {
            r.fill(1) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            var chunk = r.buffered();
            while (chunk.len > 0) {
                const res = try re.feed(chunk);
                chunk = chunk[res.consumed..];
                if (res.packet) |pkt| {
                    try self.local.writePacket(self.io, pkt);
                    self.stats.to_controller += 1;
                }
            }
            r.tossBuffered();
        }
    }

    fn localToTcp(self: *Session) !void {
        var pkt: [h4.max_packet_len]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var writer = self.tcp.writer(self.io, &write_buf);
        const w = &writer.interface;
        const fd = self.local.handle();

        while (!self.stop.load(.acquire)) {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            const n = try posix.poll(&fds, 250);
            if (n == 0) continue;
            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0 and fds[0].revents & posix.POLL.IN == 0) {
                return error.LocalEndpointClosed;
            }
            const len = try self.local.readPacket(self.io, &pkt);
            if (len == 0) return error.EndOfStream;
            if (h4.PacketType.fromByte(pkt[0]) == null) {
                log.warn("dropping packet with unknown H4 type 0x{x:0>2}", .{pkt[0]});
                continue;
            }
            try w.writeAll(pkt[0..len]);
            try w.flush();
            self.stats.to_host += 1;
        }
    }
};

/// Latency and dead peer detection settings for the bridge link.
pub fn tuneSocket(fd: posix.fd_t) !void {
    const one: c_int = 1;
    try posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one));
    const idle: c_int = 5;
    const intvl: c_int = 2;
    const cnt: c_int = 3;
    try posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPIDLE, std.mem.asBytes(&idle));
    try posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPINTVL, std.mem.asBytes(&intvl));
    try posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.KEEPCNT, std.mem.asBytes(&cnt));
}

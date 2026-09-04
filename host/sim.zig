//! hcibridge-sim: a fake ESP32 bridge for testing the host daemon without
//! hardware. Speaks H4 over TCP like the firmware, answers the HCI commands
//! bluez sends during adapter bring up, and loops ACL data back.

const std = @import("std");
const Io = std.Io;
const h4 = @import("h4");

const log = std.log.scoped(.sim);

pub const Controller = struct {
    bdaddr: [6]u8 = .{ 0xe5, 0x02, 0x00, 0xbe, 0xef, 0x01 },
    commands: u64 = 0,

    const Opcode = struct {
        const reset: u16 = 0x0c03;
        const read_local_version: u16 = 0x1001;
        const read_local_commands: u16 = 0x1002;
        const read_local_features: u16 = 0x1003;
        const read_local_ext_features: u16 = 0x1004;
        const read_buffer_size: u16 = 0x1005;
        const read_bd_addr: u16 = 0x1009;
        const le_read_buffer_size: u16 = 0x2002;
        const le_read_local_features: u16 = 0x2003;
        const le_read_supported_states: u16 = 0x201c;
    };

    /// Builds the response for one H4 packet into `out`. Returns the
    /// response length, 0 when there is nothing to say.
    pub fn handle(self: *Controller, pkt: []const u8, out: []u8) usize {
        const t = h4.PacketType.fromByte(pkt[0]) orelse return 0;
        return switch (t) {
            .command => self.handleCommand(pkt, out),
            .acl, .sco, .iso => blk: {
                @memcpy(out[0..pkt.len], pkt);
                break :blk pkt.len;
            },
            .event => 0,
        };
    }

    fn handleCommand(self: *Controller, pkt: []const u8, out: []u8) usize {
        if (pkt.len < 4) return 0;
        self.commands += 1;
        const opcode = std.mem.readInt(u16, pkt[1..3], .little);

        var params: [72]u8 = undefined;
        var plen: usize = 0;
        params[0] = 0x00;
        plen = 1;

        switch (opcode) {
            Opcode.read_bd_addr => {
                @memcpy(params[1..7], &self.bdaddr);
                plen = 7;
            },
            Opcode.read_local_version => {
                // hci_ver 5.2, hci_rev, lmp_ver 5.2, manufacturer Espressif, lmp_subver
                const v = [_]u8{ 0x0b, 0x00, 0x00, 0x0b, 0xe5, 0x02, 0x01, 0x00 };
                @memcpy(params[1 .. 1 + v.len], &v);
                plen = 1 + v.len;
            },
            Opcode.read_local_commands => {
                @memset(params[1..65], 0xff);
                plen = 65;
            },
            Opcode.read_local_features => {
                const f = [_]u8{ 0xff, 0xff, 0x8f, 0xfe, 0xdb, 0xff, 0x5b, 0x87 };
                @memcpy(params[1..9], &f);
                plen = 9;
            },
            Opcode.read_local_ext_features => {
                const page = if (pkt.len > 3) pkt[3] else 0;
                params[1] = page;
                params[2] = 2;
                @memset(params[3..11], 0);
                if (page == 0) {
                    const f = [_]u8{ 0xff, 0xff, 0x8f, 0xfe, 0xdb, 0xff, 0x5b, 0x87 };
                    @memcpy(params[3..11], &f);
                } else if (page == 1) {
                    params[3] = 0x03;
                }
                plen = 11;
            },
            Opcode.read_buffer_size => {
                // acl_len 1021, sco_len 64, acl_num 8, sco_num 0
                const b = [_]u8{ 0xfd, 0x03, 0x40, 0x08, 0x00, 0x00, 0x00 };
                @memcpy(params[1..8], &b);
                plen = 8;
            },
            Opcode.le_read_buffer_size => {
                const b = [_]u8{ 0xfb, 0x00, 0x08 };
                @memcpy(params[1..4], &b);
                plen = 4;
            },
            Opcode.le_read_local_features => {
                const f = [_]u8{ 0xff, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
                @memcpy(params[1..9], &f);
                plen = 9;
            },
            Opcode.le_read_supported_states => {
                @memset(params[1..9], 0xff);
                plen = 9;
            },
            else => {},
        }

        // Command Complete: indicator, event code, length, num_hci_cmd, opcode, params
        out[0] = @intFromEnum(h4.PacketType.event);
        out[1] = 0x0e;
        out[2] = @intCast(3 + plen);
        out[3] = 1;
        std.mem.writeInt(u16, out[4..6], opcode, .little);
        @memcpy(out[6 .. 6 + plen], params[0..plen]);
        return 6 + plen;
    }
};

pub fn serve(io: Io, stream: Io.net.Stream, ctrl: *Controller) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var storage: [h4.max_packet_len]u8 = undefined;
    var re = h4.Reassembler.init(&storage);
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var out: [h4.max_packet_len]u8 = undefined;

    while (true) {
        reader.interface.fill(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        var chunk = reader.interface.buffered();
        while (chunk.len > 0) {
            const res = try re.feed(chunk);
            chunk = chunk[res.consumed..];
            if (res.packet) |pkt| {
                const n = ctrl.handle(pkt, &out);
                if (n > 0) {
                    try writer.interface.writeAll(out[0..n]);
                    try writer.interface.flush();
                }
            }
        }
        reader.interface.tossBuffered();
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var port: u16 = 4444;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
        } else {
            log.err("usage: hcibridge-sim [--port <n>]", .{});
            return error.BadArgument;
        }
    }

    const addr: Io.net.IpAddress = .{ .ip4 = .unspecified(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    log.info("fake controller listening on port {d}", .{port});

    var ctrl: Controller = .{};
    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        log.info("host connected", .{});
        serve(io, stream, &ctrl) catch |err| log.warn("session error: {s}", .{@errorName(err)});
        log.info("host disconnected after {d} commands", .{ctrl.commands});
    }
}

const testing = std.testing;

test "reset gets a bare command complete" {
    var c: Controller = .{};
    var out: [64]u8 = undefined;
    const n = c.handle(&.{ 0x01, 0x03, 0x0c, 0x00 }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 }, out[0..n]);
}

test "read bd_addr returns the configured address" {
    var c: Controller = .{ .bdaddr = .{ 1, 2, 3, 4, 5, 6 } };
    var out: [64]u8 = undefined;
    const n = c.handle(&.{ 0x01, 0x09, 0x10, 0x00 }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x0e, 0x0a, 0x01, 0x09, 0x10, 0x00, 1, 2, 3, 4, 5, 6 }, out[0..n]);
}

test "acl is looped back" {
    var c: Controller = .{};
    var out: [64]u8 = undefined;
    const acl = [_]u8{ 0x02, 0x40, 0x00, 0x02, 0x00, 0xaa, 0xbb };
    const n = c.handle(&acl, &out);
    try testing.expectEqualSlices(u8, &acl, out[0..n]);
}

test "response length field matches" {
    var c: Controller = .{};
    var out: [128]u8 = undefined;
    inline for (.{ 0x1001, 0x1002, 0x1003, 0x1005, 0x2002, 0x0c03, 0x0c01 }) |op| {
        var cmd = [_]u8{ 0x01, 0, 0, 0 };
        std.mem.writeInt(u16, cmd[1..3], op, .little);
        const n = c.handle(&cmd, &out);
        try testing.expectEqual(n, 3 + @as(usize, out[2]));
    }
}

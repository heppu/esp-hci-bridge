//! Bluetooth HCI H4 (UART transport) packet framing.
//!
//! Every packet starts with one indicator byte followed by a fixed size
//! header that carries the payload length. This module reassembles whole
//! packets from a byte stream and is allocation free so it can be shared
//! between the host daemon and the ESP32 firmware.

const std = @import("std");

pub const PacketType = enum(u8) {
    command = 0x01,
    acl = 0x02,
    sco = 0x03,
    event = 0x04,
    iso = 0x05,

    pub fn fromByte(b: u8) ?PacketType {
        return switch (b) {
            0x01 => .command,
            0x02 => .acl,
            0x03 => .sco,
            0x04 => .event,
            0x05 => .iso,
            else => null,
        };
    }

    /// Header bytes that follow the indicator byte.
    pub fn headerLen(t: PacketType) usize {
        return switch (t) {
            .command => 3,
            .acl => 4,
            .sco => 3,
            .event => 2,
            .iso => 4,
        };
    }

    /// Payload length parsed from a complete header.
    pub fn payloadLen(t: PacketType, header: []const u8) usize {
        std.debug.assert(header.len >= t.headerLen());
        return switch (t) {
            .command => header[2],
            .event => header[1],
            .sco => header[2],
            .acl => std.mem.readInt(u16, header[2..4], .little),
            // ISO data length field is 14 bits, upper bits are reserved.
            .iso => std.mem.readInt(u16, header[2..4], .little) & 0x3fff,
        };
    }
};

/// Largest H4 packet accepted: indicator + 4 byte header + 16 bit payload.
pub const max_packet_len = 1 + 4 + 0xffff;

pub const Error = error{
    UnknownPacketType,
    PacketTooLarge,
};

pub const FeedResult = struct {
    /// Bytes consumed from the input slice.
    consumed: usize,
    /// A complete packet including the indicator byte. Valid until the next
    /// call that mutates the reassembler.
    packet: ?[]const u8,
};

/// Stream reassembler with caller provided storage.
pub const Reassembler = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Reassembler {
        std.debug.assert(buf.len >= 1 + 4);
        return .{ .buf = buf };
    }

    pub fn reset(self: *Reassembler) void {
        self.len = 0;
    }

    /// Total length of the packet being assembled, or null while the header
    /// is still incomplete.
    fn totalLen(self: *const Reassembler) Error!?usize {
        if (self.len == 0) return null;
        const t = PacketType.fromByte(self.buf[0]) orelse return error.UnknownPacketType;
        const hdr = t.headerLen();
        if (self.len < 1 + hdr) return null;
        const total = 1 + hdr + t.payloadLen(self.buf[1 .. 1 + hdr]);
        if (total > self.buf.len) return error.PacketTooLarge;
        return total;
    }

    /// Feed bytes. Call repeatedly until `consumed` reaches `input.len`.
    /// A returned packet must be handled before the next call.
    pub fn feed(self: *Reassembler, input: []const u8) Error!FeedResult {
        // A previously returned packet is still sitting in the buffer.
        if (try self.totalLen()) |total| {
            if (self.len == total) self.len = 0;
        }

        var consumed: usize = 0;
        while (consumed < input.len) {
            const total_opt = try self.totalLen();
            const want = if (total_opt) |total|
                total - self.len
            else if (self.len == 0)
                1
            else
                (1 + (PacketType.fromByte(self.buf[0]) orelse return error.UnknownPacketType).headerLen()) - self.len;

            const n = @min(want, input.len - consumed);
            @memcpy(self.buf[self.len .. self.len + n], input[consumed .. consumed + n]);
            self.len += n;
            consumed += n;

            if (try self.totalLen()) |total| {
                if (self.len == total) {
                    return .{ .consumed = consumed, .packet = self.buf[0..total] };
                }
            }
        }
        return .{ .consumed = consumed, .packet = null };
    }
};

/// Convenience: run `feed` over a slice and call `handler` for each packet.
pub fn feedAll(re: *Reassembler, input: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), []const u8) anyerror!void) anyerror!void {
    var rest = input;
    while (rest.len > 0) {
        const r = try re.feed(rest);
        rest = rest[r.consumed..];
        if (r.packet) |p| try handler(ctx, p);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Collector = struct {
    list: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,

    fn on(self: *Collector, p: []const u8) anyerror!void {
        try self.list.append(self.alloc, try self.alloc.dupe(u8, p));
    }

    fn deinit(self: *Collector) void {
        for (self.list.items) |p| self.alloc.free(p);
        self.list.deinit(self.alloc);
    }
};

const reset_cmd = [_]u8{ 0x01, 0x03, 0x0c, 0x00 };
const cmd_complete_evt = [_]u8{ 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 };
const acl_pkt = [_]u8{ 0x02, 0x40, 0x20, 0x05, 0x00, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
const sco_pkt = [_]u8{ 0x03, 0x01, 0x00, 0x02, 0x11, 0x22 };
const iso_pkt = [_]u8{ 0x05, 0x02, 0x00, 0x03, 0x40, 0x01, 0x02, 0x03 };

test "single packets of every type" {
    var storage: [64]u8 = undefined;
    inline for (.{ reset_cmd, cmd_complete_evt, acl_pkt, sco_pkt, iso_pkt }) |pkt| {
        var re = Reassembler.init(&storage);
        const r = try re.feed(&pkt);
        try testing.expectEqual(pkt.len, r.consumed);
        try testing.expectEqualSlices(u8, &pkt, r.packet.?);
    }
}

test "byte at a time" {
    var storage: [64]u8 = undefined;
    var re = Reassembler.init(&storage);
    var got: ?[]const u8 = null;
    for (acl_pkt, 0..) |b, i| {
        const r = try re.feed(&.{b});
        try testing.expectEqual(@as(usize, 1), r.consumed);
        if (i + 1 < acl_pkt.len) {
            try testing.expect(r.packet == null);
        } else {
            got = r.packet;
        }
    }
    try testing.expectEqualSlices(u8, &acl_pkt, got.?);
}

test "concatenated stream in odd chunks" {
    var storage: [64]u8 = undefined;
    var re = Reassembler.init(&storage);
    const stream = reset_cmd ++ cmd_complete_evt ++ acl_pkt ++ sco_pkt ++ iso_pkt;

    var chunk_sizes = [_]usize{ 1, 2, 3, 5, 7, 11, 13 };
    for (&chunk_sizes) |cs| {
        var c = Collector{ .alloc = testing.allocator };
        defer c.deinit();
        re.reset();
        var off: usize = 0;
        while (off < stream.len) {
            const end = @min(off + cs, stream.len);
            try feedAll(&re, stream[off..end], &c, Collector.on);
            off = end;
        }
        try testing.expectEqual(@as(usize, 5), c.list.items.len);
        try testing.expectEqualSlices(u8, &reset_cmd, c.list.items[0]);
        try testing.expectEqualSlices(u8, &cmd_complete_evt, c.list.items[1]);
        try testing.expectEqualSlices(u8, &acl_pkt, c.list.items[2]);
        try testing.expectEqualSlices(u8, &sco_pkt, c.list.items[3]);
        try testing.expectEqualSlices(u8, &iso_pkt, c.list.items[4]);
    }
}

test "two packets in one feed returns first and leaves rest unconsumed" {
    var storage: [64]u8 = undefined;
    var re = Reassembler.init(&storage);
    const stream = reset_cmd ++ cmd_complete_evt;
    const r1 = try re.feed(&stream);
    try testing.expectEqual(reset_cmd.len, r1.consumed);
    try testing.expectEqualSlices(u8, &reset_cmd, r1.packet.?);
    const r2 = try re.feed(stream[r1.consumed..]);
    try testing.expectEqual(cmd_complete_evt.len, r2.consumed);
    try testing.expectEqualSlices(u8, &cmd_complete_evt, r2.packet.?);
}

test "unknown packet type is an error" {
    var storage: [64]u8 = undefined;
    var re = Reassembler.init(&storage);
    try testing.expectError(error.UnknownPacketType, re.feed(&.{ 0x09, 0x00 }));
}

test "packet larger than storage is an error" {
    var storage: [16]u8 = undefined;
    var re = Reassembler.init(&storage);
    const big = [_]u8{ 0x02, 0x00, 0x00, 0xff, 0x00 };
    try testing.expectError(error.PacketTooLarge, re.feed(&big));
}

test "zero length payloads" {
    var storage: [64]u8 = undefined;
    var re = Reassembler.init(&storage);
    const evt = [_]u8{ 0x04, 0x10, 0x00 };
    const r = try re.feed(&evt);
    try testing.expectEqualSlices(u8, &evt, r.packet.?);
    const acl0 = [_]u8{ 0x02, 0x01, 0x00, 0x00, 0x00 };
    const r2 = try re.feed(&acl0);
    try testing.expectEqualSlices(u8, &acl0, r2.packet.?);
}

test "iso length masks reserved bits" {
    try testing.expectEqual(@as(usize, 3), PacketType.iso.payloadLen(&.{ 0x02, 0x00, 0x03, 0x40 }));
}

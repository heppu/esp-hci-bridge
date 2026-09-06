//! Tiny UDP discovery protocol for finding ESP HCI bridges on the LAN.
//!
//! Two datagram kinds, both plain ASCII so they are easy to build on the
//! firmware and easy to eyeball with tcpdump:
//!
//!   probe:    "ESPHCI1\tPROBE\n"
//!   announce: "ESPHCI1\tANNOUNCE\t<bdaddr>\t<port>\t<name>\n"
//!
//! A bridge broadcasts an announce periodically and also replies to a probe.
//! The host broadcasts a probe on startup and then just listens.

const std = @import("std");

pub const default_port: u16 = 4445;
pub const magic = "ESPHCI1";
pub const max_datagram = 256;

pub const Announcement = struct {
    /// Lowercase "aa:bb:cc:dd:ee:ff". Slice into the parsed buffer.
    bdaddr: []const u8,
    port: u16,
    /// Slice into the parsed buffer.
    name: []const u8,
};

pub const Message = union(enum) {
    probe,
    announce: Announcement,
};

pub const ParseError = error{ BadMagic, BadFormat, UnknownKind };

pub fn buildProbe(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, magic ++ "\tPROBE\n", .{}) catch unreachable;
}

pub fn buildAnnounce(buf: []u8, bdaddr: []const u8, port: u16, name: []const u8) error{NoSpace}![]u8 {
    return std.fmt.bufPrint(buf, magic ++ "\tANNOUNCE\t{s}\t{d}\t{s}\n", .{ bdaddr, port, name }) catch return error.NoSpace;
}

pub fn parse(data: []const u8) ParseError!Message {
    // Trim a single trailing newline if present.
    var line = data;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];

    var it = std.mem.splitScalar(u8, line, '\t');
    const m = it.next() orelse return error.BadFormat;
    if (!std.mem.eql(u8, m, magic)) return error.BadMagic;

    const kind = it.next() orelse return error.BadFormat;
    if (std.mem.eql(u8, kind, "PROBE")) return .probe;
    if (!std.mem.eql(u8, kind, "ANNOUNCE")) return error.UnknownKind;

    const bdaddr = it.next() orelse return error.BadFormat;
    const port_s = it.next() orelse return error.BadFormat;
    const name = it.next() orelse return error.BadFormat;
    if (it.next() != null) return error.BadFormat;
    if (bdaddr.len != 17) return error.BadFormat;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return error.BadFormat;
    if (name.len == 0) return error.BadFormat;

    return .{ .announce = .{ .bdaddr = bdaddr, .port = port, .name = name } };
}

const testing = std.testing;

test "probe round trip" {
    var buf: [64]u8 = undefined;
    const p = buildProbe(&buf);
    try testing.expect(try parse(p) == .probe);
}

test "announce round trip" {
    var buf: [128]u8 = undefined;
    const a = try buildAnnounce(&buf, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge");
    const m = try parse(a);
    try testing.expectEqualStrings("a0:a3:b3:2f:61:1e", m.announce.bdaddr);
    try testing.expectEqual(@as(u16, 4444), m.announce.port);
    try testing.expectEqualStrings("esp-hci-bridge", m.announce.name);
}

test "parse tolerates missing trailing newline" {
    const m = try parse(magic ++ "\tANNOUNCE\t11:22:33:44:55:66\t4444\tx");
    try testing.expectEqualStrings("11:22:33:44:55:66", m.announce.bdaddr);
}

test "rejects junk" {
    try testing.expectError(error.BadMagic, parse("hello world"));
    try testing.expectError(error.BadFormat, parse(magic ++ "\tANNOUNCE\t11:22\t4444\tn"));
    try testing.expectError(error.UnknownKind, parse(magic ++ "\tHELLO\n"));
    try testing.expectError(error.BadFormat, parse(magic ++ "\tANNOUNCE\taa:bb:cc:dd:ee:ff\tnotaport\tn"));
    try testing.expectError(error.BadFormat, parse(magic ++ "\tANNOUNCE\taa:bb:cc:dd:ee:ff\t4444\tn\textra"));
}

//! End to end test of the host daemon against the fake controller, with a
//! seqpacket socket pair standing in for /dev/vhci.

const std = @import("std");
const Io = std.Io;
const h4 = @import("h4");
const auth = @import("auth");
const sim = @import("sim.zig");
const session = @import("session.zig");
const handshake = @import("handshake.zig");
const testing = std.testing;

fn runSim(io: Io, server: *Io.net.Server, ctrl: *sim.Controller) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    sim.serve(io, stream, ctrl) catch {};
}

fn runSession(s: *session.Session) session.Stats {
    return s.run() catch |err| {
        std.log.err("session failed: {s}", .{@errorName(err)});
        return .{};
    };
}

test "reset round trip through daemon and sim" {
    const io = testing.io;

    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const psk: auth.Psk = [_]u8{0x5a} ** 32;
    var ctrl: sim.Controller = .{ .psk = psk };
    var sim_future = try io.concurrent(runSim, .{ io, &server, &ctrl });

    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    try session.tuneSocket(tcp.socket.handle);
    // Mutual authentication before any HCI flows.
    try handshake.client(io, tcp, &psk);

    // AF_UNIX seqpacket pair keeps packet boundaries like /dev/vhci does.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET | std.os.linux.SOCK.CLOEXEC, 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const dummy: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const local: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = dummy } };
    const fake_host: Io.net.Stream = .{ .socket = .{ .handle = fds[1], .address = dummy } };

    var s = session.Session.init(io, tcp, .{ .socket = local });
    var session_future = try io.concurrent(runSession, .{&s});

    // Host stack sends Reset, expects Command Complete back.
    var w = fake_host.writer(io, &.{});
    try w.interface.writeAll(&.{ 0x01, 0x03, 0x0c, 0x00 });
    try w.interface.flush();

    var buf: [64]u8 = undefined;
    var vec = [_][]u8{&buf};
    var r = fake_host.reader(io, &.{});
    const n = try r.interface.readVec(&vec);
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 }, buf[0..n]);

    // ACL loopback, exercises framing of a 16 bit length packet.
    const acl = [_]u8{ 0x02, 0x40, 0x20, 0x03, 0x00, 0x11, 0x22, 0x33 };
    try w.interface.writeAll(&acl);
    try w.interface.flush();
    const n2 = try r.interface.readVec(&vec);
    try testing.expectEqualSlices(u8, &acl, buf[0..n2]);

    // Closing the host side ends the session cleanly.
    fake_host.close(io);
    const stats = session_future.await(io);
    try testing.expectEqual(@as(u64, 2), stats.to_controller);
    try testing.expectEqual(@as(u64, 2), stats.to_host);

    local.close(io);
    sim_future.await(io);
}

fn runSimOnce(io: Io, server: *Io.net.Server, ctrl: *sim.Controller) ?anyerror {
    var stream = server.accept(io) catch |e| return e;
    defer stream.close(io);
    sim.serve(io, stream, ctrl) catch |e| return e;
    return null;
}

test "wrong key fails the handshake on both sides" {
    const io = testing.io;
    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var ctrl: sim.Controller = .{ .psk = [_]u8{1} ** 32 };
    var sim_future = try io.concurrent(runSimOnce, .{ io, &server, &ctrl });

    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    const wrong: auth.Psk = [_]u8{2} ** 32;
    // Board rejects our proof and closes; we either see AuthFailed or a dead socket.
    if (handshake.client(io, tcp, &wrong)) |_| return error.TestUnexpectedSuccess else |_| {}
    tcp.close(io);
    const sim_err = sim_future.await(io);
    try testing.expect(sim_err != null);
}

test "unclaimed sim refuses HCI connections" {
    const io = testing.io;
    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var ctrl: sim.Controller = .{}; // no psk
    var sim_future = try io.concurrent(runSimOnce, .{ io, &server, &ctrl });
    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    const psk: auth.Psk = [_]u8{3} ** 32;
    if (handshake.client(io, tcp, &psk)) |_| return error.TestUnexpectedSuccess else |_| {}
    tcp.close(io);
    try testing.expect(sim_future.await(io) != null);
}

fn runSilentPeer(io: Io, server: *Io.net.Server) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    var buf: [16]u8 = undefined;
    var r = stream.reader(io, &.{});
    var vec = [_][]u8{&buf};
    while (r.interface.readVec(&vec)) |_| {} else |_| {}
}

test "handshake gives up on a peer that never writes" {
    const io = testing.io;
    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var peer = try io.concurrent(runSilentPeer, .{ io, &server });

    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    const psk: auth.Psk = [_]u8{4} ** 32;
    const start = Io.Clock.Timestamp.now(io, .awake);
    try testing.expectError(error.HandshakeTimeout, handshake.clientWith(io, tcp, &psk, .{ .timeout = .fromMilliseconds(200) }));
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();
    try testing.expect(elapsed_ms >= 150 and elapsed_ms < 1000);
    tcp.close(io);
    peer.await(io);
}

test "board sending a bad proof is AuthFailed, not a dead socket" {
    const io = testing.io;
    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const psk: auth.Psk = [_]u8{5} ** 32;
    var ctrl: sim.Controller = .{ .psk = psk, .bad_mac = true };
    var sim_future = try io.concurrent(runSimOnce, .{ io, &server, &ctrl });

    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    try testing.expectError(error.AuthFailed, handshake.client(io, tcp, &psk));
    tcp.close(io);
    _ = sim_future.await(io);
}

fn runBoardThatHangsUp(io: Io, server: *Io.net.Server, psk: *const auth.Psk) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    handshake.board(io, stream, psk) catch {};
}

test "session ends promptly when the board closes first" {
    const io = testing.io;
    const listen_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const psk: auth.Psk = [_]u8{6} ** 32;
    var peer = try io.concurrent(runBoardThatHangsUp, .{ io, &server, &psk });

    const tcp = try server.socket.address.connect(io, .{ .mode = .stream });
    try session.tuneSocket(tcp.socket.handle);
    try handshake.client(io, tcp, &psk);

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET | std.os.linux.SOCK.CLOEXEC, 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const dummy: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const local: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = dummy } };
    const fake_host: Io.net.Stream = .{ .socket = .{ .handle = fds[1], .address = dummy } };
    defer local.close(io);
    defer fake_host.close(io);

    var s = session.Session.init(io, tcp, .{ .socket = local });
    const start = Io.Clock.Timestamp.now(io, .awake);
    const stats = try s.run();
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();
    try testing.expect(elapsed_ms < 1000);
    try testing.expectEqual(@as(u64, 0), stats.to_controller);
    tcp.close(io);
    peer.await(io);
}

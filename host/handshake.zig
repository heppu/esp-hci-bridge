//! Mutual challenge/response over an Io stream, both roles. Uses unbuffered
//! readers so no HCI bytes that follow the handshake are swallowed.
//!
//!   board  -> client : server_nonce
//!   client -> board  : client_nonce || HMAC(psk, server_nonce||client_nonce||"esp-hci-client")
//!   board  -> client : HMAC(psk, client_nonce||server_nonce||"esp-hci-board")

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const auth = @import("auth");

pub const Error = error{ AuthFailed, HandshakeTimeout } || anyerror;

pub const default_timeout: Io.Duration = .fromMilliseconds(5000);

pub const Options = struct {
    /// Bound on the whole exchange, so a silent peer cannot park a session.
    timeout: Io.Duration = default_timeout,
    /// Board side test hook: sign the reply with this key instead of `psk`.
    reply_psk: ?*const auth.Psk = null,
};

fn randomNonce(io: Io, out: *auth.Nonce) void {
    io.randomSecure(out) catch io.random(out);
}

fn readAllBy(io: Io, fd: posix.fd_t, buf: []u8, deadline: Io.Clock.Timestamp) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const left = deadline.durationFromNow(io).raw.toMilliseconds();
        if (left <= 0) return error.HandshakeTimeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32))));
        if (ready == 0) return error.HandshakeTimeout;
        const n = try posix.read(fd, buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

/// Client (PC) side. Returns error.AuthFailed if the board's proof is wrong.
pub fn client(io: Io, stream: Io.net.Stream, psk: *const auth.Psk) !void {
    return clientWith(io, stream, psk, .{});
}

pub fn clientWith(io: Io, stream: Io.net.Stream, psk: *const auth.Psk, opts: Options) !void {
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = opts.timeout, .clock = .awake });
    const fd = stream.socket.handle;
    var w = stream.writer(io, &.{});

    var server_nonce: auth.Nonce = undefined;
    try readAllBy(io, fd, &server_nonce, deadline);

    var client_nonce: auth.Nonce = undefined;
    randomNonce(io, &client_nonce);
    const cmac = auth.clientMac(psk, &server_nonce, &client_nonce);
    try w.interface.writeAll(&client_nonce);
    try w.interface.writeAll(&cmac);
    try w.interface.flush();

    var bmac: auth.Mac = undefined;
    try readAllBy(io, fd, &bmac, deadline);
    const expect = auth.boardMac(psk, &client_nonce, &server_nonce);
    if (!auth.ctEqual(&bmac, &expect)) return error.AuthFailed;
}

/// Board side (used by the simulator; the firmware implements the same in C).
pub fn board(io: Io, stream: Io.net.Stream, psk: *const auth.Psk) !void {
    return boardWith(io, stream, psk, .{});
}

pub fn boardWith(io: Io, stream: Io.net.Stream, psk: *const auth.Psk, opts: Options) !void {
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = opts.timeout, .clock = .awake });
    const fd = stream.socket.handle;
    var w = stream.writer(io, &.{});

    var server_nonce: auth.Nonce = undefined;
    randomNonce(io, &server_nonce);
    try w.interface.writeAll(&server_nonce);
    try w.interface.flush();

    var msg: [auth.nonce_len + auth.mac_len]u8 = undefined;
    try readAllBy(io, fd, &msg, deadline);
    const client_nonce: *const auth.Nonce = msg[0..auth.nonce_len];
    const cmac = msg[auth.nonce_len..];
    const expect = auth.clientMac(psk, &server_nonce, client_nonce);
    if (!auth.ctEqual(cmac, &expect)) return error.AuthFailed;

    const bmac = auth.boardMac(opts.reply_psk orelse psk, client_nonce, &server_nonce);
    try w.interface.writeAll(&bmac);
    try w.interface.flush();
}

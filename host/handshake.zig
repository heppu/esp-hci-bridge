//! Mutual challenge/response over an Io stream, both roles. Uses unbuffered
//! readers so no HCI bytes that follow the handshake are swallowed.
//!
//!   board  -> client : server_nonce
//!   client -> board  : client_nonce || HMAC(psk, server_nonce||client_nonce||"esp-hci-client")
//!   board  -> client : HMAC(psk, client_nonce||server_nonce||"esp-hci-board")

const std = @import("std");
const Io = std.Io;
const auth = @import("auth");

pub const Error = error{AuthFailed} || anyerror;

fn randomNonce(io: Io, out: *auth.Nonce) void {
    io.randomSecure(out) catch io.random(out);
}

/// Client (PC) side. Returns error.AuthFailed if the board's proof is wrong.
pub fn client(io: Io, stream: Io.net.Stream, psk: *const auth.Psk) !void {
    var r = stream.reader(io, &.{});
    var w = stream.writer(io, &.{});

    var server_nonce: auth.Nonce = undefined;
    try r.interface.readSliceAll(&server_nonce);

    var client_nonce: auth.Nonce = undefined;
    randomNonce(io, &client_nonce);
    const cmac = auth.clientMac(psk, &server_nonce, &client_nonce);
    try w.interface.writeAll(&client_nonce);
    try w.interface.writeAll(&cmac);
    try w.interface.flush();

    var bmac: auth.Mac = undefined;
    try r.interface.readSliceAll(&bmac);
    const expect = auth.boardMac(psk, &client_nonce, &server_nonce);
    if (!auth.ctEqual(&bmac, &expect)) return error.AuthFailed;
}

/// Board side (used by the simulator; the firmware implements the same in C).
pub fn board(io: Io, stream: Io.net.Stream, psk: *const auth.Psk) !void {
    var r = stream.reader(io, &.{});
    var w = stream.writer(io, &.{});

    var server_nonce: auth.Nonce = undefined;
    randomNonce(io, &server_nonce);
    try w.interface.writeAll(&server_nonce);
    try w.interface.flush();

    var msg: [auth.nonce_len + auth.mac_len]u8 = undefined;
    try r.interface.readSliceAll(&msg);
    const client_nonce: *const auth.Nonce = msg[0..auth.nonce_len];
    const cmac = msg[auth.nonce_len..];
    const expect = auth.clientMac(psk, &server_nonce, client_nonce);
    if (!auth.ctEqual(cmac, &expect)) return error.AuthFailed;

    const bmac = auth.boardMac(psk, client_nonce, &server_nonce);
    try w.interface.writeAll(&bmac);
    try w.interface.flush();
}

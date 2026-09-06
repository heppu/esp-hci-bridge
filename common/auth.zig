//! Authentication shared by host, simulator, and (as a spec) the firmware.
//!
//! A 32-byte pre-shared key (PSK) per board, established once with X25519 at
//! claim time, then used for:
//!   * a mutual HMAC-SHA256 challenge/response before any HCI byte flows,
//!   * signing discovery announcements,
//!   * authenticating HTTP OTA/reboot requests.
//! Every construction here is plain HMAC-SHA256 / SHA-256 / X25519 so the C
//! side (mbedTLS) computes identical values.

const std = @import("std");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;

pub const psk_len = 32;
pub const nonce_len = 32;
pub const mac_len = 32;
pub const Psk = [psk_len]u8;
pub const Nonce = [nonce_len]u8;
pub const Mac = [mac_len]u8;

/// Domain separators. Fixed strings, same bytes in the firmware.
pub const dom_client = "esp-hci-client";
pub const dom_board = "esp-hci-board";
pub const announce_sig_hex_len = 32; // first 16 bytes of the MAC, hex encoded

pub fn hmac(key: []const u8, parts: []const []const u8) Mac {
    var h = Hmac.init(key);
    for (parts) |p| h.update(p);
    var out: Mac = undefined;
    h.final(&out);
    return out;
}

pub fn ctEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ---------------------------------------------------------------------------
// Transport handshake (TCP 4444), run before H4 flows.
//   S->C: server_nonce
//   C->S: client_nonce || HMAC(psk, server_nonce || client_nonce || dom_client)
//   S->C: HMAC(psk, client_nonce || server_nonce || dom_board)
// ---------------------------------------------------------------------------

pub fn clientMac(psk: *const Psk, server_nonce: *const Nonce, client_nonce: *const Nonce) Mac {
    return hmac(psk, &.{ server_nonce, client_nonce, dom_client });
}

pub fn boardMac(psk: *const Psk, client_nonce: *const Nonce, server_nonce: *const Nonce) Mac {
    return hmac(psk, &.{ client_nonce, server_nonce, dom_board });
}

// ---------------------------------------------------------------------------
// Announce signature: hex of first 16 bytes of
// HMAC(psk, "bdaddr\tport\tname\ta.b.c.d") where a.b.c.d is the board's own
// IPv4 address. The host checks it against the datagram source, so a captured
// announce cannot be replayed from another machine.
// ---------------------------------------------------------------------------

pub fn announceSig(psk: *const Psk, bdaddr: []const u8, port: u16, name: []const u8, ip: [4]u8, out: *[announce_sig_hex_len]u8) []const u8 {
    var pbuf: [8]u8 = undefined;
    const port_s = std.fmt.bufPrint(&pbuf, "{d}", .{port}) catch unreachable;
    var ibuf: [16]u8 = undefined;
    const ip_s = std.fmt.bufPrint(&ibuf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
    const m = hmac(psk, &.{ bdaddr, "\t", port_s, "\t", name, "\t", ip_s });
    const hex = std.fmt.bytesToHex(m[0..16], .lower);
    @memcpy(out, &hex);
    return out;
}

pub fn verifyAnnounce(psk: *const Psk, bdaddr: []const u8, port: u16, name: []const u8, ip: [4]u8, sig: []const u8) bool {
    var expect: [announce_sig_hex_len]u8 = undefined;
    _ = announceSig(psk, bdaddr, port, name, ip, &expect);
    return ctEqual(&expect, sig);
}

// ---------------------------------------------------------------------------
// HTTP proofs. The board publishes a nonce in its status JSON: 16 random bytes
// chosen at boot followed by a big-endian 32-bit counter that advances after
// every accepted request, so a captured proof is dead after it is used once.
//
//   X-Bridge-Auth: hex(HMAC(psk, "<METHOD> <path>\n" || nonce || SHA256(body)))
//   X-Bridge-Pre:  hex(HMAC(psk, "PRE <METHOD> <path>\n" || nonce || be32(content_length)))
//
// Pre is checked before the body is read, so an upload without the key never
// touches flash. Auth is checked after the body, before the image is activated.
// ---------------------------------------------------------------------------

pub const http_nonce_len = 20;
pub const HttpNonce = [http_nonce_len]u8;

pub fn httpAuth(psk: *const Psk, method: []const u8, path: []const u8, nonce: *const HttpNonce, body: []const u8, out: *[mac_len * 2]u8) []const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    const m = hmac(psk, &.{ method, " ", path, "\n", nonce, &digest });
    const hex = std.fmt.bytesToHex(m, .lower);
    @memcpy(out, &hex);
    return out;
}

pub fn httpPre(psk: *const Psk, method: []const u8, path: []const u8, nonce: *const HttpNonce, content_len: u32, out: *[mac_len * 2]u8) []const u8 {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, content_len, .big);
    const m = hmac(psk, &.{ "PRE ", method, " ", path, "\n", nonce, &len_be });
    const hex = std.fmt.bytesToHex(m, .lower);
    @memcpy(out, &hex);
    return out;
}

/// Proof format of firmware before v0.10.3 (no nonce, replayable). Only used to
/// push a fixed image onto boards that still run it.
pub fn httpAuthLegacy(psk: *const Psk, method: []const u8, path: []const u8, body: []const u8, out: *[mac_len * 2]u8) []const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    const m = hmac(psk, &.{ method, " ", path, "\n", &digest });
    const hex = std.fmt.bytesToHex(m, .lower);
    @memcpy(out, &hex);
    return out;
}

pub fn hexToNonce(hex: []const u8) ?HttpNonce {
    if (hex.len != http_nonce_len * 2) return null;
    var n: HttpNonce = undefined;
    _ = std.fmt.hexToBytes(&n, hex) catch return null;
    return n;
}

// ---------------------------------------------------------------------------
// Claim: X25519 then PSK = SHA256(shared secret)
// ---------------------------------------------------------------------------

pub fn derivePsk(secret_key: [32]u8, peer_public: [32]u8) !Psk {
    const shared = try X25519.scalarmult(secret_key, peer_public);
    var psk: Psk = undefined;
    Sha256.hash(&shared, &psk, .{});
    return psk;
}

pub fn hexToPsk(hex: []const u8) ?Psk {
    if (hex.len != psk_len * 2) return null;
    var psk: Psk = undefined;
    _ = std.fmt.hexToBytes(&psk, hex) catch return null;
    return psk;
}

pub fn pskToHex(psk: *const Psk) [psk_len * 2]u8 {
    return std.fmt.bytesToHex(psk, .lower);
}

const testing = std.testing;

test "hmac known answer (RFC 4231 case 2)" {
    // key = "Jefe", data = "what do ya want for nothing?"
    const m = hmac("Jefe", &.{"what do ya want for nothing?"});
    const hex = std.fmt.bytesToHex(m, .lower);
    try testing.expectEqualStrings("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", &hex);
}

test "handshake macs verify and are direction-bound" {
    const psk: Psk = [_]u8{7} ** 32;
    const sn: Nonce = [_]u8{1} ** 32;
    const cn: Nonce = [_]u8{2} ** 32;
    const c = clientMac(&psk, &sn, &cn);
    const b = boardMac(&psk, &cn, &sn);
    try testing.expect(!ctEqual(&c, &b));
    try testing.expect(ctEqual(&c, &clientMac(&psk, &sn, &cn)));
    var wrong = psk;
    wrong[0] ^= 1;
    try testing.expect(!ctEqual(&c, &clientMac(&wrong, &sn, &cn)));
}

test "announce sign/verify" {
    const psk: Psk = [_]u8{9} ** 32;
    var sig: [announce_sig_hex_len]u8 = undefined;
    _ = announceSig(&psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", .{ 172, 16, 135, 242 }, &sig);
    const ip: [4]u8 = .{ 172, 16, 135, 242 };
    try testing.expect(verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", ip, &sig));
    try testing.expect(!verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4445, "esp-hci-bridge", ip, &sig));
    try testing.expect(!verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4444, "evil", ip, &sig));
    try testing.expect(!verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", .{ 172, 16, 135, 243 }, &sig));
}

test "claim derives the same psk on both sides" {
    const a_sk: [32]u8 = [_]u8{0x11} ** 32;
    const b_sk: [32]u8 = [_]u8{0x22} ** 32;
    const a_pk = try X25519.recoverPublicKey(a_sk);
    const b_pk = try X25519.recoverPublicKey(b_sk);
    const a = try derivePsk(a_sk, b_pk);
    const b = try derivePsk(b_sk, a_pk);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "psk hex round trip" {
    const psk: Psk = [_]u8{0xab} ** 32;
    const hex = pskToHex(&psk);
    try testing.expectEqualSlices(u8, &psk, &(hexToPsk(&hex).?));
    try testing.expect(hexToPsk("short") == null);
}

// Known answers computed with Python hmac/hashlib. If the firmware and this
// file ever disagree, one of them changed the byte layout.
const kat_psk: Psk = [_]u8{0x42} ** 32;
const kat_server_nonce: Nonce = [_]u8{0x01} ** 32;
const kat_client_nonce: Nonce = [_]u8{0x02} ** 32;
const kat_http_nonce: HttpNonce = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 };

test "clientMac known answer" {
    const m = clientMac(&kat_psk, &kat_server_nonce, &kat_client_nonce);
    try testing.expectEqualStrings("2fe39892c5e63ee8db176f30fc167c6dca28c3c7b6de9f282db5a6cb19c469fb", &std.fmt.bytesToHex(m, .lower));
}

test "boardMac known answer" {
    const m = boardMac(&kat_psk, &kat_client_nonce, &kat_server_nonce);
    try testing.expectEqualStrings("1b4c57c4b9475964807cb64cb09f4e9e8b965e528879dffe7da6b16e5bc760c3", &std.fmt.bytesToHex(m, .lower));
}

test "announceSig known answer" {
    var sig: [announce_sig_hex_len]u8 = undefined;
    _ = announceSig(&kat_psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", .{ 172, 16, 135, 242 }, &sig);
    try testing.expectEqualStrings("f31c4827ed4d937c2384e8e08b99cf52", &sig);
}

test "httpAuth known answer" {
    var mac: [mac_len * 2]u8 = undefined;
    _ = httpAuth(&kat_psk, "POST", "/ota", &kat_http_nonce, "hello", &mac);
    try testing.expectEqualStrings("d73a6fdc38fd0d275ea4598553abf13d07f8faee5edacb4a6e8d5ecf968a2d6b", &mac);
}

test "httpPre known answer" {
    var mac: [mac_len * 2]u8 = undefined;
    _ = httpPre(&kat_psk, "POST", "/ota", &kat_http_nonce, 5, &mac);
    try testing.expectEqualStrings("8a27ffcc95c766a804fdb997ada1fd22f1dcc3b09fbe676250823a8e6b04f0b1", &mac);
}

test "httpAuthLegacy known answer" {
    var mac: [mac_len * 2]u8 = undefined;
    _ = httpAuthLegacy(&kat_psk, "POST", "/ota", "hello", &mac);
    try testing.expectEqualStrings("a5a0c35d2853c43b6c49d62f9e96b169c90907f876817ccd96505fe92ad2a72f", &mac);
}

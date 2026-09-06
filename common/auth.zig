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
// Announce signature: hex of first 16 bytes of HMAC(psk, "bdaddr\tport\tname").
// ---------------------------------------------------------------------------

pub fn announceSig(psk: *const Psk, bdaddr: []const u8, port: u16, name: []const u8, out: *[announce_sig_hex_len]u8) []const u8 {
    var pbuf: [8]u8 = undefined;
    const port_s = std.fmt.bufPrint(&pbuf, "{d}", .{port}) catch unreachable;
    const m = hmac(psk, &.{ bdaddr, "\t", port_s, "\t", name });
    const hex = std.fmt.bytesToHex(m[0..16], .lower);
    @memcpy(out, &hex);
    return out;
}

pub fn verifyAnnounce(psk: *const Psk, bdaddr: []const u8, port: u16, name: []const u8, sig: []const u8) bool {
    var expect: [announce_sig_hex_len]u8 = undefined;
    _ = announceSig(psk, bdaddr, port, name, &expect);
    return ctEqual(&expect, sig);
}

// ---------------------------------------------------------------------------
// HTTP auth header: hex(HMAC(psk, "<METHOD> <path>\n" || SHA256(body)))
// ---------------------------------------------------------------------------

pub fn httpAuth(psk: *const Psk, method: []const u8, path: []const u8, body: []const u8, out: *[mac_len * 2]u8) []const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    const m = hmac(psk, &.{ method, " ", path, "\n", &digest });
    const hex = std.fmt.bytesToHex(m, .lower);
    @memcpy(out, &hex);
    return out;
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
    _ = announceSig(&psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", &sig);
    try testing.expect(verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4444, "esp-hci-bridge", &sig));
    try testing.expect(!verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4445, "esp-hci-bridge", &sig));
    try testing.expect(!verifyAnnounce(&psk, "a0:a3:b3:2f:61:1e", 4444, "evil", &sig));
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

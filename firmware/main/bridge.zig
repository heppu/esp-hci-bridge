//! ESP32 side of the bridge. Owns the TCP server and the byte pumps between
//! the socket and the Bluetooth controller's virtual HCI interface.
//!
//! SDK specific setup (Ethernet, controller init, FreeRTOS objects) lives
//! in glue.c and is reached through the `glue` externs below.

const std = @import("std");
const h4 = @import("h4");

const glue = struct {
    extern fn glue_listen(port: u16) c_int;
    extern fn glue_accept(lfd: c_int) c_int;
    extern fn glue_poll2(a: c_int, b: c_int, timeout_ms: c_int) c_int;
    extern fn glue_recv(fd: c_int, buf: [*]u8, len: usize) c_int;
    extern fn glue_send(fd: c_int, buf: [*]const u8, len: usize) c_int;
    extern fn glue_close(fd: c_int) void;
    extern fn glue_sb_create(size: usize) ?*anyopaque;
    extern fn glue_sb_send(sb: *anyopaque, data: [*]const u8, len: usize, timeout_ms: u32) usize;
    extern fn glue_sb_recv(sb: *anyopaque, buf: [*]u8, len: usize, timeout_ms: u32) usize;
    extern fn glue_sb_space(sb: *anyopaque) usize;
    extern fn glue_sem_create() ?*anyopaque;
    extern fn glue_sem_take(sem: *anyopaque, timeout_ms: u32) bool;
    extern fn glue_sem_give(sem: *anyopaque) void;
    extern fn glue_task_create(func: *const fn (?*anyopaque) callconv(.c) void, name: [*:0]const u8, stack: u32, prio: u32, core: c_int) bool;
    extern fn glue_delay_ms(ms: u32) void;
    extern fn glue_millis() u32;
    extern fn glue_log(level: c_int, msg: [*:0]const u8) void;
    extern fn glue_abort(msg: [*:0]const u8) noreturn;
    extern fn glue_wdt_add() void;
    extern fn glue_wdt_feed() void;
    extern fn glue_bt_send_available() bool;
    extern fn glue_bt_send(data: [*]const u8, len: u16) void;
    extern fn glue_tcp_port() u16;
};

const log = std.log.scoped(.bridge);

/// Host to controller packets: commands are at most 259 bytes, ACL is
/// bounded by the controller buffer size (1021 + 5).
const rx_packet_len = 1 + 4 + 1021;
const rx_chunk_len = 1024;
const tx_chunk_len = 1024;
/// Controller to host queue. Fills only when the host stalls.
const stream_buffer_len = 16 * 1024;
/// How long to wait for the controller to accept a packet before dropping.
const send_wait_ms = 5000;
const stats_interval_ms = 60_000;

const Stats = struct {
    to_controller: u32 = 0,
    to_host: u32 = 0,
    dropped_no_host: u32 = 0,
    dropped_overflow: u32 = 0,
    dropped_stale: u32 = 0,
    dropped_controller_busy: u32 = 0,
    connections: u32 = 0,
};

const State = struct {
    listen_fd: c_int = -1,
    client_fd: std.atomic.Value(i32) = .init(-1),
    /// Handshake so the rx task can drain the stream buffer while the tx
    /// task is parked, otherwise bytes of the previous host could leak into
    /// the new connection.
    tx_pause: std.atomic.Value(bool) = .init(false),
    tx_idle: std.atomic.Value(bool) = .init(false),
    sb: ?*anyopaque = null,
    send_sem: ?*anyopaque = null,
    stats: Stats = .{},
};

var state: State = .{};
var rx_storage: [rx_packet_len]u8 = undefined;
var rx_chunk: [rx_chunk_len]u8 = undefined;
var tx_chunk: [tx_chunk_len]u8 = undefined;

// ---------------------------------------------------------------------------
// Entry points called from glue.c
// ---------------------------------------------------------------------------

export fn bridge_start() void {
    state.sb = glue.glue_sb_create(stream_buffer_len) orelse @panic("stream buffer alloc failed");
    state.send_sem = glue.glue_sem_create() orelse @panic("semaphore alloc failed");
    if (!glue.glue_task_create(rxTask, "hci_rx", 6144, 12, 1)) @panic("rx task create failed");
    if (!glue.glue_task_create(txTask, "hci_tx", 4096, 12, 1)) @panic("tx task create failed");
    log.info("bridge started", .{});
}

/// Called from the controller task for every HCI packet headed to the host.
export fn bridge_on_controller_packet(data: [*]u8, len: u16) c_int {
    if (state.client_fd.load(.acquire) < 0) {
        state.stats.dropped_no_host +%= 1;
        return 0;
    }
    const sb = state.sb orelse return 0;
    // Whole packets only, a partial write would desync the host stream.
    if (glue.glue_sb_space(sb) < len) {
        state.stats.dropped_overflow +%= 1;
        return 0;
    }
    _ = glue.glue_sb_send(sb, data, len, 0);
    state.stats.to_host +%= 1;
    return 0;
}

export fn bridge_stats_json(buf: [*]u8, len: usize) usize {
    const s = state.stats;
    const out = std.fmt.bufPrintZ(buf[0..len], "{{\"to_controller\":{d},\"to_host\":{d},\"connections\":{d},\"connected\":{},\"drop_no_host\":{d},\"drop_overflow\":{d},\"drop_stale\":{d},\"drop_busy\":{d}}}", .{
        s.to_controller, s.to_host, s.connections, state.client_fd.load(.acquire) >= 0, s.dropped_no_host, s.dropped_overflow, s.dropped_stale, s.dropped_controller_busy,
    }) catch {
        buf[0] = 0;
        return 0;
    };
    return out.len;
}

export fn bridge_on_controller_send_available() void {
    if (state.send_sem) |sem| glue.glue_sem_give(sem);
}

// ---------------------------------------------------------------------------
// TCP to controller
// ---------------------------------------------------------------------------

fn rxTask(_: ?*anyopaque) callconv(.c) void {
    glue.glue_wdt_add();
    const port = glue.glue_tcp_port();
    state.listen_fd = glue.glue_listen(port);
    if (state.listen_fd < 0) @panic("tcp listen failed");
    log.info("listening on tcp port {d}", .{port});

    var re = h4.Reassembler.init(&rx_storage);
    var last_stats = glue.glue_millis();

    while (true) {
        glue.glue_wdt_feed();
        const client = state.client_fd.load(.acquire);
        const ready = glue.glue_poll2(state.listen_fd, client, 1000);
        if (ready < 0) {
            log.err("poll failed", .{});
            glue.glue_delay_ms(100);
            continue;
        }
        if (ready & 1 != 0) acceptClient(&re);
        if (ready & 2 != 0 and client >= 0) {
            const n = glue.glue_recv(client, &rx_chunk, rx_chunk.len);
            if (n <= 0) {
                dropClient("host closed connection");
                continue;
            }
            var chunk: []const u8 = rx_chunk[0..@intCast(n)];
            while (chunk.len > 0) {
                const res = re.feed(chunk) catch |err| {
                    log.err("bad H4 stream from host: {s}", .{@errorName(err)});
                    re.reset();
                    dropClient("protocol error");
                    break;
                };
                chunk = chunk[res.consumed..];
                if (res.packet) |pkt| sendToController(pkt);
            }
        }
        const now = glue.glue_millis();
        if (now -% last_stats >= stats_interval_ms) {
            last_stats = now;
            if (state.client_fd.load(.acquire) >= 0) logStats();
        }
    }
}

fn acceptClient(re: *h4.Reassembler) void {
    const new_fd = glue.glue_accept(state.listen_fd);
    if (new_fd < 0) return;

    const old = state.client_fd.swap(-1, .acq_rel);
    if (old >= 0) {
        log.warn("replacing existing host connection", .{});
        glue.glue_close(old);
    }
    re.reset();
    state.tx_pause.store(true, .release);
    while (!state.tx_idle.load(.acquire)) glue.glue_delay_ms(1);
    drainStreamBuffer();
    state.client_fd.store(new_fd, .release);
    state.tx_pause.store(false, .release);
    state.stats.connections +%= 1;
    log.info("host connected", .{});
}

fn dropClient(reason: []const u8) void {
    const old = state.client_fd.swap(-1, .acq_rel);
    if (old < 0) return;
    glue.glue_close(old);
    log.info("host disconnected: {s}", .{reason});
    logStats();
}

/// Throws away queued controller packets so a new host starts on a packet
/// boundary. The producer skips writes while no client is set.
fn drainStreamBuffer() void {
    const sb = state.sb orelse return;
    while (glue.glue_sb_recv(sb, &tx_chunk, tx_chunk.len, 0) > 0) {}
}

fn sendToController(pkt: []const u8) void {
    const sem = state.send_sem orelse return;
    const deadline = glue.glue_millis() +% send_wait_ms;
    while (!glue.glue_bt_send_available()) {
        _ = glue.glue_sem_take(sem, 20);
        if (glue.glue_millis() -% deadline < 0x8000_0000) {
            state.stats.dropped_controller_busy +%= 1;
            log.err("controller not accepting packets, dropping one", .{});
            return;
        }
    }
    glue.glue_bt_send(pkt.ptr, @intCast(pkt.len));
    state.stats.to_controller +%= 1;
}

// ---------------------------------------------------------------------------
// Controller to TCP
// ---------------------------------------------------------------------------

fn txTask(_: ?*anyopaque) callconv(.c) void {
    const sb = state.sb orelse @panic("no stream buffer");
    while (true) {
        if (state.tx_pause.load(.acquire)) {
            state.tx_idle.store(true, .release);
            glue.glue_delay_ms(2);
            continue;
        }
        state.tx_idle.store(false, .release);
        const n = glue.glue_sb_recv(sb, &tx_chunk, tx_chunk.len, 100);
        if (n == 0) continue;
        // Read the client after the wait, a host may have connected meanwhile.
        const client = state.client_fd.load(.acquire);
        if (client < 0) {
            state.stats.dropped_stale +%= 1;
            continue;
        }
        if (glue.glue_send(client, &tx_chunk, n) < 0) {
            dropClient("send failed");
        }
    }
}

fn logStats() void {
    const s = state.stats;
    log.info("stats: to_ctrl={d} to_host={d} conns={d} drop_nohost={d} drop_overflow={d} drop_stale={d} drop_busy={d}", .{
        s.to_controller, s.to_host, s.connections, s.dropped_no_host, s.dropped_overflow, s.dropped_stale, s.dropped_controller_busy,
    });
}

// ---------------------------------------------------------------------------
// std hooks for a freestanding target
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = espLog,
};

fn espLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, format, args) catch blk: {
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    };
    const esp_level: c_int = switch (level) {
        .err => 1,
        .warn => 2,
        .info => 3,
        .debug => 4,
    };
    glue.glue_log(esp_level, msg.ptr);
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    var buf: [128]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    glue.glue_abort(buf[0..n :0].ptr);
}

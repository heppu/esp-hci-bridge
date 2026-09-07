//! Terminal output for the command line tool: steps, progress bars, errors.
//! Everything goes to stderr so stdout stays usable for data (list, status).
const std = @import("std");
const Io = std.Io;

pub const Ui = struct {
    io: Io,
    file: Io.File,
    tty: bool,
    /// A step is open from `step` until `done` or `fail` closes its line.
    open: bool = false,

    pub fn init(io: Io) Ui {
        const f = Io.File.stderr();
        return .{ .io = io, .file = f, .tty = f.isTty(io) catch false };
    }

    fn write(self: *Ui, bytes: []const u8) void {
        var buf: [256]u8 = undefined;
        var w = self.file.writer(self.io, &buf);
        w.interface.writeAll(bytes) catch return;
        w.interface.flush() catch {};
    }

    fn print(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(s);
    }

    /// Starts a line that `done` completes: "Checking the latest release... v1.2".
    pub fn step(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        if (self.open) self.write("\n");
        self.print(fmt ++ "...", args);
        self.open = true;
    }

    pub fn done(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.print(" " ++ fmt ++ "\n", args);
        self.open = false;
    }

    /// A complete line on its own.
    pub fn info(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        if (self.open) self.write("\n");
        self.open = false;
        self.print(fmt ++ "\n", args);
    }

    pub fn warn(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.info("warning: " ++ fmt, args);
    }

    /// The problem on one line, what to do about it on the next.
    pub fn fail(self: *Ui, comptime what: []const u8, what_args: anytype, comptime hint: []const u8, hint_args: anytype) void {
        if (self.open) self.write("\n");
        self.open = false;
        self.print("error: " ++ what ++ "\n", what_args);
        if (hint.len > 0) self.print("  " ++ hint ++ "\n", hint_args);
    }

    /// A progress bar that redraws in place on a terminal and stays quiet
    /// otherwise, apart from the final line.
    pub fn progress(self: *Ui, comptime label: []const u8, args: anytype, total: usize) Progress {
        var p = Progress{ .ui = self, .total = total };
        p.label_len = if (std.fmt.bufPrint(&p.label, label, args)) |s| s.len else |_| 0;
        if (self.open) self.write("\n");
        self.open = false;
        p.draw(0, true);
        return p;
    }
};

pub const Progress = struct {
    ui: *Ui,
    total: usize,
    label: [64]u8 = undefined,
    label_len: usize = 0,
    last_pct: usize = 101,
    finished: bool = false,

    pub fn update(self: *Progress, done: usize) void {
        self.draw(done, false);
    }

    pub fn finish(self: *Progress, done: usize) void {
        if (self.finished) return;
        self.finished = true;
        const pct: usize = if (self.total == 0) 100 else @min(100, done * 100 / self.total);
        if (pct != self.last_pct) self.draw(done, true);
        if (self.ui.tty) self.ui.write("\n");
    }

    fn draw(self: *Progress, done: usize, force: bool) void {
        const pct: usize = if (self.total == 0) 100 else @min(100, done * 100 / self.total);
        if (!force and pct == self.last_pct) return;
        if (!self.ui.tty and !force) return;
        self.last_pct = pct;
        var bar: [20]u8 = undefined;
        const filled = pct * bar.len / 100;
        for (&bar, 0..) |*c, i| c.* = if (i < filled) '#' else '.';
        var kb: [2][]const u8 = .{ "", "" };
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        kb[0] = human(done, &b1);
        kb[1] = human(self.total, &b2);
        if (self.ui.tty) self.ui.write("\r");
        self.ui.print("{s}  [{s}] {d: >3}%  {s} of {s}", .{ self.label[0..self.label_len], &bar, pct, kb[0], kb[1] });
        if (!self.ui.tty) self.ui.write("\n");
    }
};

fn human(n: usize, buf: *[16]u8) []const u8 {
    if (n >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ n / (1024 * 1024), (n % (1024 * 1024)) * 10 / (1024 * 1024) }) catch "?";
    if (n >= 1024) return std.fmt.bufPrint(buf, "{d} KB", .{n / 1024}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

/// "a.b.c.d" without the port, for messages about a board.
pub fn ipOf(addr: *const Io.net.IpAddress, buf: *[48]u8) []const u8 {
    return switch (addr.*) {
        .ip4 => |v| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ v.bytes[0], v.bytes[1], v.bytes[2], v.bytes[3] }) catch "?",
        else => std.fmt.bufPrint(buf, "{f}", .{addr.*}) catch "?",
    };
}

/// Plain words for the errors a user can actually do something about.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.NameServerFailure, error.TemporaryNameServerFailure, error.UnknownHostName, error.HostLacksNetworkAddresses => "name lookup failed, is DNS working?",
        error.ConnectionRefused => "connection refused",
        error.ConnectionTimedOut, error.Timeout => "connection timed out",
        error.NetworkUnreachable => "network unreachable",
        error.ConnectionResetByPeer, error.EndOfStream, error.HttpConnectionClosing => "connection dropped",
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => "TLS setup failed, are system CA certificates installed?",
        error.ChecksumMismatch => "the downloaded image does not match the release checksums",
        error.NoSuchBoardImage => "the release has no image for that board",
        error.HttpStatus => "unexpected HTTP status (see above)",
        error.AuthFailed => "the board rejected this key",
        error.HandshakeTimeout => "the board did not answer the handshake",
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        else => @errorName(err),
    };
}
